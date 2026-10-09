# The QA signal lives in EnvironmentBanner (pure Ruby, unit-tested). Required
# EXPLICITLY rather than leaned on: s3.rb is loadable on its own — the unit suite
# requires it directly without lib/studio.rb — so an implicit dependency here
# resolves in the app and raises NoMethodError in a test.
require_relative "environment_banner"

module Studio
  module S3
    class Error < StandardError; end
    class NotConfigured < Error; end

    class << self
      def upload(key:, body:, content_type: nil, cache_control: nil)
        opts = { bucket: bucket, key: full_key(key), body: body }
        opts[:content_type] = content_type if content_type
        opts[:cache_control] = cache_control if cache_control
        client.put_object(**opts)
        public_url? ? url(key: key) : nil
      end

      # max_bytes reads only the head of the object (a ranged GET), which is
      # how a preview looks at the first megabyte of a file of any size and
      # how a caller enforces a size cap without trusting a recorded length.
      # A ranged read of an EMPTY object is a 416 (InvalidRange) on S3; that
      # is answered as the empty string it means. Tested against a stubbed
      # client only: no live store, R2 included, has been asked.
      def download(key:, max_bytes: nil)
        # 0 or a negative would build "bytes=0--1", which a store may read as
        # no range at all and answer with the whole object.
        unless max_bytes.nil? || (max_bytes.is_a?(Integer) && max_bytes.positive?)
          raise ArgumentError, "max_bytes must be a positive Integer, got #{max_bytes.inspect}"
        end

        opts = { bucket: bucket, key: full_key(key) }
        opts[:range] = "bytes=0-#{max_bytes - 1}" if max_bytes
        s3 = client
        # The rescue names an SDK constant, so it wraps only what runs after
        # the client (which loads the SDK) exists: an unconfigured app must
        # raise NotConfigured from `bucket` above, not a NameError from here.
        begin
          s3.get_object(**opts).body.read
        rescue Aws::S3::Errors::InvalidRange
          raise unless max_bytes

          "".b
        end
      end

      # The PUBLIC URL of an object. On AWS (no endpoint) it is the bucket's
      # virtual-hosted amazonaws.com URL, byte-identical to every version before
      # endpoints existed. On an S3-compatible endpoint it is Studio.s3_public_url
      # plus the key, and without that base it RAISES: R2's S3 endpoint answers no
      # anonymous request, so any URL built from it would be a broken image in an
      # inbox, not an error anyone sees. Private objects want signed_url.
      def url(key:)
        base = Studio.s3_public_url.to_s
        return "#{base.chomp("/")}/#{full_key(key)}" unless base.empty?
        raise NotConfigured, "Studio.s3_public_url not set: #{endpoint} serves no public URL (use signed_url for private objects)" if endpoint

        "https://#{bucket}.s3.#{region}.amazonaws.com/#{full_key(key)}"
      end

      # Whether url can answer. upload asks this so an app with only private
      # objects (a data room on R2 with no public domain) can still write:
      # upload returns nil there instead of raising AFTER the object landed.
      def public_url?
        endpoint.nil? || !Studio.s3_public_url.to_s.empty?
      end

      # response_content_disposition and response_content_type are SIGNED into
      # the URL and override the headers the object is served with. That is
      # S3's documented behaviour and part of the S3 compatibility Cloudflare
      # documents for R2. What the tests here prove is the SIGNING, against an
      # R2-style endpoint; that R2 serves the overridden headers has not been
      # verified against a live bucket. "inline" plus a content type the
      # caller chose is how a private PDF or image is shown in the page
      # without the stored content type deciding how the browser treats it.
      def signed_url(key:, expires_in: 3600, response_content_disposition: nil, response_content_type: nil)
        require "aws-sdk-s3"
        params = { bucket: bucket, key: full_key(key), expires_in: expires_in }
        params[:response_content_disposition] = response_content_disposition if response_content_disposition
        params[:response_content_type] = response_content_type if response_content_type
        Aws::S3::Presigner.new(client: client).presigned_url(:get_object, **params)
      end

      def exists?(key:)
        client.head_object(bucket: bucket, key: full_key(key))
        true
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
        false
      end

      # A RECOVERABLE delete: the object moves under trash/ in the same bucket
      # (Studio::S3::Trash) and the bucket's lifecycle rule expires it after
      # three days. Returns the trash key, or nil when there was nothing to
      # move. Refused outright when a non-production process is pointed at a
      # production bucket. purge! is the delete that cannot be undone.
      def delete(key:)
        target = bucket
        guard_production_bucket!(target)
        Trash.trash!(client: client, bucket: target, key: full_key(key), env: deletion_environment)
      end

      # The HARD delete, gone at once with no trash copy. For objects with no
      # value after deletion (regenerable derivatives, a trash copy itself).
      # The same production-bucket guard as delete.
      def purge!(key:)
        target = bucket
        guard_production_bucket!(target)
        client.delete_object(bucket: target, key: full_key(key))
      end

      # Returns LOGICAL keys (the app's key namespace stripped back off), so a
      # caller can feed any result straight back into download/delete/url.
      # Trashed objects are deleted objects, so trash/ keys are left out unless
      # include_trash: true. The filter runs after S3's max_keys, so a listing
      # with trash in range can return fewer than max keys.
      def list(prefix: nil, max: 1000, include_trash: false)
        resp = client.list_objects_v2(bucket: bucket, prefix: full_key(prefix), max_keys: max)
        keys = resp.contents.map(&:key)
        keys = keys.reject { |key| Trash.trash_key?(key) } unless include_trash
        keys.map { |key| logical_key(key) }
      end

      # Whether this process is real production, by the SAME resolution that
      # picks the bucket half (QA_ENV first, then Rails.env). Public because the
      # Active Storage trash service guards on it too.
      def production_environment?
        environment == "production"
      end

      # A non-production process (a laptop, a QA app, CI) may never delete from
      # a bucket named "*-production", whoever handed it the bucket name or the
      # key. Studio::S3 derives its bucket from the same environment, so here it
      # is a backstop; for an Active Storage service, whose bucket comes from
      # storage.yml, it is the guard.
      def guard_production_bucket!(bucket_name)
        return unless bucket_name.to_s.end_with?("-production")
        return if production_environment?

        raise Trash::ProductionBucketRefused,
              "refusing to delete from #{bucket_name}: this process resolves to a non-production " \
              "environment (#{deletion_environment}); only production deletes production objects"
      end

      # The environment a trash copy records in its deleted-env metadata:
      # "qa" for a QA app (which runs Rails as production), else Rails.env.
      def deletion_environment
        return "qa" if EnvironmentBanner.qa_environment?
        return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env) && Rails.env

        "unknown"
      end

      def bucket
        prefix = Studio.s3_bucket_prefix
        raise NotConfigured, "Studio.s3_bucket_prefix not set in config/initializers/studio.rb" if prefix.nil? || prefix.empty?
        "#{prefix}-#{environment}"
      end

      # Whether this app can touch object storage at all. Callers that must
      # degrade rather than 500 (the /admin/emails uploader on an app whose
      # bucket was never provisioned) ask this instead of rescuing NotConfigured.
      def configured?
        bucket
        true
      rescue NotConfigured
        false
      end

      # Studio.s3_key_prefix, normalized to "" or "something/". The namespace a
      # satellite app lives under when it shares another app's bucket.
      def key_prefix
        prefix = Studio.s3_key_prefix.to_s
        return "" if prefix.empty?

        prefix.end_with?("/") ? prefix : "#{prefix}/"
      end

      # Logical key -> the real object key in the bucket.
      def full_key(key)
        return key if key.nil?

        "#{key_prefix}#{key}"
      end

      # The real object key -> logical key (inverse of full_key).
      def logical_key(key)
        prefix = key_prefix
        return key if prefix.empty? || !key.to_s.start_with?(prefix)

        key.to_s.delete_prefix(prefix)
      end

      def region
        Studio.s3_region
      end

      # The S3-compatible endpoint (R2: https://<account>.r2.cloudflarestorage.com),
      # or nil for AWS. Blank reads as unset, so an empty ENV var cannot point the
      # client at "".
      def endpoint
        value = Studio.s3_endpoint.to_s
        value.empty? ? nil : value
      end

      def client
        @client ||= begin
          require "aws-sdk-s3"
          Aws::S3::Client.new(**client_options)
        end
      end

      # Only what is configured is passed, so an unconfigured app builds exactly
      # the client it always did: region alone, the SDK's default credential chain.
      # Keys are passed as a PAIR or not at all; half a pair is a configuration
      # error, and falling back to the default chain would silently write with
      # whatever AWS_* key the dyno happens to hold.
      def client_options
        opts = { region: region }
        opts[:endpoint] = endpoint if endpoint
        id = Studio.s3_access_key_id.to_s
        secret = Studio.s3_secret_access_key.to_s
        if id.empty? != secret.empty?
          raise NotConfigured, "Studio.s3_access_key_id and s3_secret_access_key must be set together"
        end
        unless id.empty?
          opts[:access_key_id] = id
          opts[:secret_access_key] = secret
        end
        opts
      end

      def reset!
        @client = nil
      end

      private

      # WHICH BUCKET HALF THIS APP OWNS. Rails.env alone cannot answer it: no QA app
      # sets RAILS_ENV, so every QA app boots as `production` exactly like real
      # production. QA_ENV is the signal that separates them, and it is the one
      # config/storage.yml (Active Storage), Studio::EnvironmentBanner and
      # turf-monster's AppFlags already read — so consulting it here makes BOTH S3
      # writers agree instead of resolving different buckets from the same process.
      #
      # Before this, a QA app holding the DEV key was handed the PRODUCTION bucket:
      # every write took an IAM AccessDenied (uncaught — the knowledge_docs
      # controller rescues only NotConfigured/MissingTable), and a LIST returned
      # production's confidential objects to a review environment.
      #
      # `Studio.qa_environment?` delegates to EnvironmentBanner.truthy?, so
      # `QA_ENV=false` correctly reads as production rather than as mere presence.
      def environment
        return "dev" if EnvironmentBanner.qa_environment?

        # ASKS FOR THE METHOD, NOT THE CONSTANT, and the difference is not
        # theoretical. rails-html-sanitizer — which arrives with action_view, long
        # before any Rails APPLICATION does — defines a namespace-only `module
        # Rails` with no singleton methods on it. Against that, a bare
        # `defined?(Rails)` reads TRUE and the very next call dies with
        # NoMethodError: undefined method `env` for module Rails. It turned an
        # unrelated green suite red the first time a unit test pulled action_view
        # in.
        #
        # THIS WAS NOT THE LAST ONE, though it was described that way when it
        # landed. Three sites still carried the bare form afterwards — both
        # keyword defaults in lib/studio/mail_transport.rb and the developer-desk
        # route guard in lib/studio.rb — and the claim that the sweep was finished
        # is how they survived a second review. The whole tree is swept now, and
        # test/lib/studio/rails_guard_sweep_test.rb is what keeps it that way; do
        # not restate completeness here, because a comment cannot notice the next
        # straggler and that test can.
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env&.production? ? "production" : "dev"
      end
    end
  end
end

require_relative "s3/trash"
