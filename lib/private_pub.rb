require "digest/sha1"
require "net/http"
require "net/https"

require "private_pub/faye_extension"
require "private_pub/engine" if defined? Rails

module PrivatePub
	
	class Error < StandardError; end

	class << self
		attr_reader :config

		# Resets the configuration to the default (empty hash)
		def reset_config
			@config = {}
		end

		# Loads the configuration from a given YAML file and environment (such as production)
		def load_config(filename, environment)
			yaml = YAML.load_file(filename)[environment.to_s]
			raise ArgumentError, "The #{environment} environment does not exist in #{filename}" if yaml.nil?
			yaml.each { |k, v| config[k.to_sym] = v }
		end

		# Publish the given data to a specific channel. This ends up sending
		# a Net::HTTP POST request to the Faye server.
		def publish_to(channel, data)
			publish_message(message(channel, data))
		end

		# Sends the given message hash to the Faye server using Net::HTTP.
		def publish_message(message)
			raise Error, "No server specified, ensure private_pub.yml was loaded properly." unless config[:server]
			uri = URI.parse(config[:server])

			form = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
			form.set_form_data(:message => message.to_json)

			http = Net::HTTP.new(uri.host, uri.port)
			http.use_ssl = uri.scheme == 'https'
			http.start {|h| h.request(form)}
		end

		# Returns a message hash for sending to Faye
		def message(channel, data)
			message = {:channel => channel, :data => {:channel => channel}, :ext => {:private_pub_token => config[:secret_token]}}
			if data.kind_of? String
				message[:data][:eval] = data
			else
				message[:data][:data] = data
			end
			message
		end

		# Returns a subscription hash to pass to the PrivatePub.sign call in JavaScript.
		# Any options passed are merged to the hash.
		def subscription(options = {})
			# provide the client with another (i.e. the external address) if given
			sub = {server: config[:server_external] || config[:server], timestamp: (Time.now.to_f * 1000).round}.merge(options)
			sub[:signature] = Digest::SHA1.hexdigest([config[:secret_token], sub[:channel], sub[:timestamp]].join)
			sub
		end

		# Determine if the signature has expired given a timestamp.
		def signature_expired?(timestamp)
			timestamp < ((Time.now.to_f - config[:signature_expiration])*1000).round if config[:signature_expiration]
		end

		# Returns the Faye Rack application.
		# Any options given are passed to the Faye::RackAdapter.
		def faye_app(options = {})
			# set up the Faye logger
			Faye.logger = Logger.new(STDOUT)
			Faye.logger.level = Logger::WARN
			
			fe = FayeExtension.new(config)
			options = {mount: '/faye', timeout: 25, extensions: [fe]}.merge(options)
			Faye::RackAdapter.new(options)
		end
	end

	reset_config
end
