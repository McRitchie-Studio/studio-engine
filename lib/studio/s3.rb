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
        url(key: key)
      end

      def download(key:)
        client.get_object(bucket: bucket, key: full_key(key)).body.read
      end

      def url(key:)
        "https://#{bucket}.s3.#{region}.amazonaws.com/#{full_key(key)}"
      end

      def signed_url(key:, expires_in: 3600)
        require "aws-sdk-s3"
        Aws::S3::Presigner.new(client: client).presigned_url(:get_object, bucket: bucket, key: full_key(key), expires_in: expires_in)
      end

      def exists?(key:)
        client.head_object(bucket: bucket, key: full_key(key))
        true
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
        false
      end

      def delete(key:)
        client.delete_object(bucket: bucket, key: full_key(key))
      end

      # Returns LOGICAL keys (the app's key namespace stripped back off), so a
      # caller can feed any result straight back into download/delete/url.
      def list(prefix: nil, max: 1000)
        resp = client.list_objects_v2(bucket: bucket, prefix: full_key(prefix), max_keys: max)
        resp.contents.map { |object| logical_key(object.key) }
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

      def client
        @client ||= begin
          require "aws-sdk-s3"
          Aws::S3::Client.new(region: region)
        end
      end

      def reset!
        @client = nil
      end

      private

      def environment
        defined?(Rails) && Rails.env.production? ? "production" : "dev"
      end
    end
  end
end
