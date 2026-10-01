# frozen_string_literal: true

require "erb"

module Studio
  # The house link-preview primitive: what an unfurl (iMessage, Slack, Discord,
  # X, WhatsApp...) shows when someone pastes a link to this app.
  #
  # Deliberately PURE, like Studio::Geo: plain strings in, plain strings and
  # hashes out, no request and no database. The pieces that need the world live
  # beside it:
  #
  #   Studio::SiteIdentity  (model) the operator's default image, title and
  #                               description, set at /admin/link_preview
  #   Studio::LinkPreviewHelper   (view helper) the page override
  #                               (`link_preview`) and the tags the head renders
  #   Studio::LinkPreviewBots     (controller concern) the slim document preview
  #                               fetchers get instead of the full page
  #
  # Lifted from turf-monster (OgHelper, SiteSetting, OgImageAttachable and the
  # app-local LinkPreviewBot of task imessage-link-preview-fix), which carried
  # all of this in production first. See docs/LINK_PREVIEW.md.
  module LinkPreview
    # Apple's LinkPresentation (the iMessage unfurler, which runs on the SENDER's
    # phone) aborts any HTML page over this many bytes with WebKitErrorDomain 102,
    # "Frame load interrupted". Measured 2026-09-30: 1,048,000 bytes previewed,
    # 1,049,000 failed. The slim document is held under it.
    MAX_DOCUMENT_BYTES = 1_048_576

    # The preview fetchers, by User-Agent token. An ALLOW-LIST: only an agent
    # named here gets the slim document; a person, or an agent nobody named,
    # always gets the full page. Each token is a product's own FETCHER, not its
    # in-app browser: Facebook's in-app browser sends FBAN/FBAV, LinkedIn's sends
    # LinkedInApp, X's sends "Twitter for iPhone", and none of those match.
    #
    # iMessage has no token of its own. LinkPresentation sends an old-Safari UA
    # suffixed "facebookexternalhit/1.1 Facebot Twitterbot/1.0", so it rides the
    # Facebook and X tokens.
    BOT_TOKENS = [
      "facebookexternalhit",    # Facebook, Messenger; also Apple LinkPresentation (iMessage)
      "Facebot",                # Facebook; also iMessage
      "Twitterbot",             # X; also iMessage
      "Discordbot",
      "Slackbot-LinkExpanding",
      "LinkedInBot",
      "WhatsApp/",              # the fetcher sends WhatsApp/<version>
      "TelegramBot",
      "Applebot",               # Siri / Spotlight suggestions
      "SkypeUriPreview",        # Skype and Teams
      "redditbot",
      "Embedly"
    ].freeze

    BOT_PATTERN = Regexp.union(BOT_TOKENS.map { |token| /#{Regexp.escape(token)}/i }).freeze

    # What the slim document keeps from the page's head. Everything a fetcher
    # reads for a card, and nothing it executes: no script, style or template.
    KEPT_META_NAMES = %w[
      description robots theme-color application-name author keywords
    ].freeze
    KEPT_LINK_RELS = %w[
      canonical icon shortcut\ icon apple-touch-icon apple-touch-icon-precomposed manifest mask-icon image_src
    ].freeze

    module_function

    # The first view template under `views_root` that writes its own og:title or
    # og:image, or nil. Studio.link_preview_tags? asks this under :auto, so an
    # app that still writes its own preview tags (turf-monster's
    # layouts/_link_preview_meta, cyvasse's layouts/_seo) does not get a second
    # set the day it installs the engine's migrations — which docs/
    # NEW_APP_SETUP.md tells every app to do after every upgrade.
    #
    # Deliberately BROAD: any mention counts, a comment included. A false
    # positive only keeps the engine's tags off (an app sets
    # link_preview_tags = true to override); a false negative would double them.
    OWN_TAG_PATTERN = /og:(?:title|image)\b/
    TEMPLATE_GLOB = "**/*.{erb,haml,slim}"

    def own_tag_file(views_root)
      root = views_root.to_s
      return nil if root.empty? || !File.directory?(root)

      Dir.glob(File.join(root, TEMPLATE_GLOB)).sort.find do |path|
        File.read(path, encoding: "UTF-8").scrub.match?(OWN_TAG_PATTERN)
      rescue SystemCallError
        false
      end
    end

    # Is this User-Agent a link-preview fetcher? Blank is never a bot.
    def bot?(user_agent)
      ua = user_agent.to_s
      return false if ua.strip.empty?

      BOT_PATTERN.match?(ua)
    end

    # THE RESOLUTION CHAIN. Each argument is a list of rungs, most specific
    # first; the first present rung wins.
    #
    #   title        page override(s) -> operator default -> site name
    #   description  page override(s) -> operator default -> none (tag omitted)
    #   image        page override(s) -> operator default -> static fallback -> none
    #
    # A page override with NO image (a user with no avatar) is simply a blank
    # rung, so it falls through to the default: that is the whole override rule.
    # `image_source` says which rung answered (:page, :default, :static, :none).
    def resolve(site_name:, titles: [], descriptions: [], page_images: [], default_image: nil, static_image: nil)
      page_image = first_present(page_images)
      image, source =
        if page_image then [page_image, :page]
        elsif present?(default_image) then [default_image.to_s, :default]
        elsif present?(static_image) then [static_image.to_s, :static]
        else [nil, :none]
        end

      {
        title: first_present(titles) || site_name.to_s,
        description: first_present(descriptions),
        image: image,
        image_source: source
      }
    end

    # An image URL a fetcher can follow from anywhere. Unfurlers resolve nothing
    # relative, so a root-relative path is joined to the request's base URL; a
    # protocol-relative one is given https. Absolute URLs pass through.
    def absolute_url(url, base_url:)
      value = url.to_s.strip
      return nil if value.empty?
      return "https:#{value}" if value.start_with?("//")
      return "#{base_url.to_s.chomp("/")}#{value}" if value.start_with?("/")

      value
    end

    # The base URL every preview URL is built on: the app's PINNED canonical
    # base (Studio.link_preview_base_url) when it set one, else the request's.
    # Trailing slash dropped, so a path joins cleanly. nil when neither exists.
    def base_url(pinned:, request_base_url:)
      pinned_value = pinned.to_s.strip.chomp("/")
      return pinned_value unless pinned_value.empty?

      request_value = request_base_url.to_s.strip.chomp("/")
      request_value.empty? ? nil : request_value
    end

    # The page's og:url. With a pinned base it is that base plus the PATH: no
    # herokuapp host, no ?utm_ query, so every share of a page counts as one URL.
    # Without one it is the URL as requested, as it always was.
    def page_url(base_url:, request_url:, path:)
      pinned_value = base_url.to_s.strip.chomp("/")
      return request_url.to_s.empty? ? nil : request_url.to_s if pinned_value.empty?

      "#{pinned_value}#{path.to_s.empty? ? "/" : path}"
    end

    # [width, height] of a PNG, GIF, JPEG or WebP file, read from its header
    # only, or nil when the file is missing, unreadable or another format. Lets
    # the static fallback (public/og.png) emit og:image:width/height, which
    # WhatsApp and others use to lay the card out before the image arrives.
    def image_dimensions(path)
      File.open(path.to_s, "rb") { |file| dimensions_from(file.read(64 * 1024).to_s.b) }
    rescue SystemCallError, IOError
      nil
    end

    def dimensions_from(bytes)
      dims =
        if bytes.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.bytesize >= 24
          bytes[16, 8].unpack("NN")
        elsif bytes.start_with?("GIF8") && bytes.bytesize >= 10
          bytes[6, 4].unpack("vv")
        elsif bytes.start_with?("\xFF\xD8".b)
          jpeg_dimensions(bytes)
        elsif bytes.start_with?("RIFF") && bytes[8, 4] == "WEBP"
          webp_dimensions(bytes)
        end
      dims && dims.all? { |n| n.is_a?(Integer) && n.positive? } ? dims : nil
    end

    # Walk the JPEG segments to the first start-of-frame marker.
    JPEG_SOF_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze

    def jpeg_dimensions(bytes)
      offset = 2
      while offset + 9 <= bytes.bytesize
        return nil unless bytes.getbyte(offset) == 0xFF

        marker = bytes.getbyte(offset + 1)
        if marker == 0xFF # fill byte
          offset += 1
          next
        end
        length = bytes[offset + 2, 2].unpack1("n")
        if JPEG_SOF_MARKERS.include?(marker)
          height, width = bytes[offset + 5, 4].unpack("nn")
          return [width, height]
        end
        return nil if length.nil? || length < 2

        offset += 2 + length
      end
      nil
    end

    def webp_dimensions(bytes)
      case bytes[12, 4]
      when "VP8 "
        return nil if bytes.bytesize < 30

        width, height = bytes[26, 4].unpack("vv")
        [width & 0x3FFF, height & 0x3FFF]
      when "VP8L"
        return nil if bytes.bytesize < 25

        bits = bytes[21, 4].unpack1("V")
        [(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1]
      when "VP8X"
        return nil if bytes.bytesize < 30

        w = bytes[24, 3].unpack("CCC")
        h = bytes[27, 3].unpack("CCC")
        [(w[0] | (w[1] << 8) | (w[2] << 16)) + 1, (h[0] | (h[1] << 8) | (h[2] << 16)) + 1]
      end
    end

    # The whole response a preview fetcher gets: the page's own identity tags,
    # lifted out of its <head>, and a one-card body. Built FROM the rendered
    # page, so the slim document cannot drift from what a person's page says.
    #
    # DUPLICATE-SAFE: a meta tag named twice (an app emitting its own og tags
    # AND the engine's) is kept once, the FIRST occurrence — the one the page
    # put first, which is the one an app that owns its tags writes.
    def slim_document(html, url: nil)
      source = html.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      head = source[%r{<head\b[^>]*>(.*?)</head\s*>}mi, 1] || source
      head = head.gsub(%r{<(script|style|template|noscript)\b.*?</\1\s*>}mi, "").gsub(/<!--.*?-->/m, "")
      lang = source[/<html\b[^>]*\blang\s*=\s*["']([^"']+)["']/i, 1]
      title = head[%r{<title\b[^>]*>(.*?)</title\s*>}mi, 1]&.strip

      tags = kept_tags(head)
      document = build_document(tags, title: title, lang: lang, url: url)
      return document if document.bytesize < MAX_DOCUMENT_BYTES

      # A head that is itself enormous (an inline data: icon, say). Keep only
      # what an unfurl card is made of.
      core = tags.select { |tag| tag_key(tag).to_s.match?(/\A(og:|twitter:|description\z)/) }
      build_document(core, title: title, lang: lang, url: url)
    end

    def kept_tags(head)
      seen = {}
      head.scan(/<meta\b[^>]*>|<link\b[^>]*>/i).select do |tag|
        next false unless keep_tag?(tag)

        key = tag_key(tag)
        next true if key.nil?
        next false if seen[key]

        seen[key] = true
      end
    end

    def keep_tag?(tag)
      if tag.match?(/\A<link/i)
        rel = attribute(tag, "rel").to_s.downcase.strip
        return KEPT_LINK_RELS.include?(rel)
      end
      return false if attribute(tag, "charset") # the document writes its own

      property = attribute(tag, "property").to_s
      return true unless property.empty?

      name = attribute(tag, "name").to_s.downcase
      name.start_with?("twitter:") || KEPT_META_NAMES.include?(name)
    end

    # The identity a duplicate is judged by: a meta's property or name, a link's
    # rel. Case-folded, because <meta name="Description"> is the same claim.
    def tag_key(tag)
      if tag.match?(/\A<link/i)
        rel = attribute(tag, "rel")
        return rel ? "link:#{rel.downcase}:#{attribute(tag, "sizes")}" : nil
      end
      (attribute(tag, "property") || attribute(tag, "name"))&.downcase
    end

    def attribute(tag, name)
      tag[/\s#{Regexp.escape(name)}\s*=\s*"([^"]*)"/i, 1] || tag[/\s#{Regexp.escape(name)}\s*=\s*'([^']*)'/i, 1]
    end

    def build_document(tags, title:, lang:, url:)
      og_title = content_of(tags, "og:title") || title
      og_description = content_of(tags, "og:description") || content_of(tags, "description")
      lang_attr = lang ? %( lang="#{ERB::Util.html_escape(lang)}") : ""

      body = +""
      body << "<h1>#{og_title}</h1>\n" if og_title
      body << "<p>#{og_description}</p>\n" if og_description
      body << %(<p><a href="#{ERB::Util.html_escape(url)}">#{og_title || ERB::Util.html_escape(url)}</a></p>\n) if url

      <<~HTML
        <!DOCTYPE html>
        <html#{lang_attr}>
        <head>
        <meta charset="utf-8">
        #{"<title>#{title}</title>\n" if title}#{tags.join("\n")}
        </head>
        <body>
        #{body}</body>
        </html>
      HTML
    end

    # Already escaped: the value came out of a rendered attribute, so it is
    # emitted back into markup exactly as the page wrote it.
    def content_of(tags, key)
      tag = tags.find { |t| tag_key(t) == key }
      tag && attribute(tag, "content")
    end

    def first_present(values)
      Array(values).each do |value|
        return value.to_s.strip if present?(value)
      end
      nil
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
