# frozen_string_literal: true

module Studio
  # THE PARENT MAP behind studio/_page_header's crumb trail (docs/PAGE_HEADER.md, "Crumbs").
  # An app names each page that has children once, with its label, its address and its own
  # parent. A page then names only its parent, and the trail builds itself up the chain.
  #
  #   # config/initializers/studio_crumbs.rb
  #   Studio.crumbs.draw do
  #     page :admin,       "Admin",       :admin_dashboard_path
  #     page :deployments, "Deployments", :deployments_path, parent: :admin
  #     page :release,     ->(release:) { release.slug }, ->(release:) { release_path(release) },
  #          parent: :deployments
  #   end
  #
  #   <%= render "studio/page_header", title: "Deployments", crumbs: studio_crumbs(:deployments) %>
  #   <%= render "studio/page_header", title: @task.title, crumbs: studio_crumbs(parent: :deployments) %>
  #
  # A label or an address is a String, a Symbol (a route helper, read in the view, then on
  # main_app) or a lambda the view runs with the page's own keywords.
  class Crumbs
    Page = Struct.new(:key, :label, :path, :parent, keyword_init: true)

    class UnknownPage < KeyError; end
    class Cycle < ArgumentError; end

    def initialize
      @pages = {}
    end

    def draw(&block)
      instance_eval(&block)
      self
    end

    def page(key, label, path, parent: nil)
      @pages[key.to_sym] = Page.new(key: key.to_sym, label: label, path: path, parent: parent&.to_sym)
    end

    def clear
      @pages.clear
      self
    end

    def key?(key) = @pages.key?(key.to_sym)

    def fetch(key)
      @pages.fetch(key.to_sym) { raise UnknownPage, "Studio.crumbs has no page #{key.inspect}" }
    end

    # The keys from the root down to `key`, `key` included.
    def chain(key)
      keys = []
      current = key&.to_sym
      while current
        raise Cycle, "Studio.crumbs loops at #{current.inspect}" if keys.include?(current)

        keys.unshift(current)
        current = fetch(current).parent
      end
      keys
    end

    # The trail for one page: its ancestors, root first, as [{ label:, href: }]. Name the page
    # itself (`key`, the page in the map) or only its parent (`parent:`, a page not in the map).
    def trail(view, key = nil, parent: nil, **locals)
      raise ArgumentError, "name the page or its parent, not both" if key && parent

      keys = key ? chain(key)[0...-1] : chain(parent)
      keys.map do |name|
        page = fetch(name)
        { label: resolve(view, page.label, locals).to_s, href: resolve(view, page.path, locals).to_s }
      end
    end

    # The map's page at `path`, or nil: for a page the engine draws (the style guide, the
    # model pages), which cannot know the host's key for it. Only pages whose address
    # needs no keywords can match.
    def key_for_path(view, path)
      wanted = path.to_s.chomp("/").presence || "/"
      @pages.each_value do |page|
        next if page.path.is_a?(Proc) && keywords(page.path, required: true).any?

        address = begin
          resolve(view, page.path, {}).to_s
        rescue StandardError
          next
        end
        return page.key if address.chomp("/").presence == wanted || (wanted == "/" && address == "/")
      end
      nil
    end

    private

    def resolve(view, value, locals)
      case value
      when Proc then view.instance_exec(**locals.slice(*keywords(value)), &value)
      when Symbol then route(view, value)
      else value
      end
    end

    def keywords(proc, required: false)
      kinds = required ? %i[keyreq] : %i[key keyreq]
      proc.parameters.filter_map { |kind, name| name if kinds.include?(kind) }
    end

    def route(view, name)
      return view.public_send(name) if view.respond_to?(name)
      return view.main_app.public_send(name) if view.respond_to?(:main_app)

      raise NoMethodError, "Studio.crumbs: no route helper #{name}"
    end
  end

  def self.crumbs
    @crumbs ||= Crumbs.new
  end
end
