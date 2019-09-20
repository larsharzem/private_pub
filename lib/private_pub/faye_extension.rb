require 'redis'
require 'net/http'
require 'thread'

module PrivatePub
	# This class is an extension for the Faye::RackAdapter.
	# It is used inside of PrivatePub.faye_app.
	class FayeExtension
		@@rails_server = 'http://localhost'
		
		def initialize(options_hash = {})
			options_hash.delete(:redis_address) # delete unused parameter
			options_hash[:redis_server] ||= '127.0.0.1'
			options_hash[:redis_port] ||= 6379
			options_hash[:redis_password] ||= nil
			@@rails_server = options_hash[:rails_server] unless options_hash[:rails_server].nil?
			if options_hash[:redis_password].nil?
				Redis.current = Redis.new(host: options_hash[:redis_server], port: options_hash[:redis_port])
			else
				Redis.current = Redis.new(host: options_hash[:redis_server], port: options_hash[:redis_port], password: options_hash[:redis_password])
			end
			puts "initialize faye extension, options: #{options_hash}\nRedis client: #{Redis.current.inspect}"
			return self
		end
	
		# Callback to handle incoming Faye messages. This authenticates both
		# subscribe and publish calls.
		def incoming(message, callback)
			#puts "\n#{Time.now} incoming, msg", message
			
			if message["channel"] == "/meta/subscribe"
				authenticate_subscribe(message)
			elsif message["channel"] !~ %r{^/meta/}
				authenticate_publish(message)
			else
				maintain_channel_subscriptions(message)
			end
			
			message['data']['channel'] ||= message['channel'] if message['data']
			callback.call(message)
		end

		
		private

			# Ensure the subscription signature is correct and that it has not expired.
			def authenticate_subscribe(message)
				subscription = PrivatePub.subscription(:channel => message["subscription"], :timestamp => message["ext"]["private_pub_timestamp"])
				#Redis.current.hset('log', "#{Time.now.to_i}_auth", {message_subscription: message["subscription"], client_id: message['clientId']})
				if message["ext"]["private_pub_signature"] != subscription[:signature]
					message["error"] = "Incorrect signature."
				elsif PrivatePub.signature_expired? message["ext"]["private_pub_timestamp"].to_i
					message["error"] = "Signature has expired."
				elsif message["subscription"].index('/feed/actor') == 0
					puts "\nincoming new subscription: #{message["subscription"]}"
					current_subsciptions = Redis.current.hgetall('subscriptions')
					present_subscription = current_subsciptions[message["subscription"]]
					puts "already present sub by this actor? #{!present_subscription.nil? && present_subscription.length != 0}"
					if present_subscription
						client_ids = eval(present_subscription)[:client_ids]
						client_ids[message['clientId']] = Time.now.to_i
					else
						client_ids = {message['clientId'] => Time.now.to_i}
					end
					## begin try
					begin
						puts "writing new subscription, now #{client_ids.length} channels in total"
						Redis.current.hset('subscriptions', message["subscription"], {time: Time.now.to_i, client_ids: client_ids})
						ping_online_actors_change_to_rails(message["subscription"], 'subscribing')
					rescue Exception => e
						puts "\nException: #{e}\n"
					end
					## end try
				end
			end

			# Ensures the secret token is correct before publishing.
			def authenticate_publish(message)
				if PrivatePub.config[:secret_token].nil?
					raise Error, "No secret_token config set, ensure private_pub.yml is loaded properly."
				elsif message["ext"].nil? || (message["ext"]["private_pub_token"] != PrivatePub.config[:secret_token] && !credentials_valid?(message))
					message["error"] = "Incorrect or no token."
				else
					message["ext"]["private_pub_token"] = nil
				end
			end
			
			def credentials_valid?(message)
				return message['ext']['private_pub_signature'] == Digest::SHA1.hexdigest([PrivatePub.config[:secret_token], message['channel'], message['ext']['private_pub_timestamp']].join)
			end
			
			def maintain_channel_subscriptions(message)
				begin ## begin try
					current_subsciptions = Redis.current.hgetall('subscriptions')
					puts "\n#{Time.now} incoming, current_subsciptions: #{current_subsciptions.keys.join(', ')}"
					#Redis.current.hset('log', "#{Time.now.to_i}_inco", {message: message, current_subsciptions: current_subsciptions})
					
					return unless current_subsciptions
					message_client_id = message['clientId']
					key = current_subsciptions.find{|k, v| eval(v)[:client_ids] != nil && eval(v)[:client_ids][message_client_id]}
					puts "this user's subscription: #{key ? ("#{key.first} --> #{eval(key.last)[:client_ids].length} channels, latest update: #{Time.at(eval(key.last)[:time])}") : "NONE, returning"}"
					
					return unless key && key.first.index('/feed/actor') == 0
					channel = key.first
					channel_hash = eval(current_subsciptions[channel])
					if message['channel'] == '/meta/disconnect'
						if channel_hash[:client_ids].length > 1
							puts "\ndisconnect, deleting channel. channels left: #{channel_hash[:client_ids].length - 1}"
							channel_hash[:client_ids].delete(message_client_id)
							Redis.current.hset('subscriptions', channel, channel_hash)
						else
							puts "disconnect, deleting user's subscription (no channels left)"
							Redis.current.hdel('subscriptions', channel)
							
							puts "now: #{Redis.current.hgetall('subscriptions')}"
							ping_online_actors_change_to_rails(channel, 'disconnecting')
						end
					else
						channel_hash[:time] = Time.now.to_i
						puts "performing cleanup for subscription:"
						channel_hash[:client_ids] = cleanup_client_id_timestamps(channel_hash[:client_ids], message_client_id)
						
						puts "updating timestamps for subscription of channel #{channel}: #{channel_hash[:client_ids].length} channels, latest update: #{Time.now}"
						Redis.current.hset('subscriptions', channel, channel_hash)
					end # don't do anything for /meta/unsubscribe
				
				rescue Exception => e
					puts "\nException: #{e}\n"
				end ## end try
			end
			
			def cleanup_client_id_timestamps(client_ids, current_client_id)
				client_ids.each_with_index do |(client_id, timestamp), index|
					if client_id == current_client_id
						puts "index #{index}: found id, updating"
						client_ids[client_id] = Time.now.to_i
					elsif Time.now.to_i - timestamp > 50 # 2 * the keep alive time
						puts "index #{index}: deleting, grace time exceeded"
						client_ids.delete(client_id)
					else
						puts "index #{index}: omitting delete, grace time not exceeded"
					end
				end
				
				return client_ids
			end
			
			def ping_online_actors_change_to_rails(feed, reason)
				uri = URI.parse("#{@@rails_server}/update_online_actors_ping?trigger_actor_id=#{feed.split('_').last}&reason=#{reason}&token_digest=#{Digest::SHA1.hexdigest(PrivatePub.config[:secret_token])}")
				req = Net::HTTP::Get.new(uri.to_s)
				Thread.new do
					begin ## begin try
						http = Net::HTTP.new(uri.host, uri.port)
						http.open_timeout = 2 # in seconds
						http.read_timeout = 2 # in seconds
						http.use_ssl = uri.scheme == 'https'
						# SSL cert will not match, but we should always be able to trust stuff on the same machine
						http.verify_mode = OpenSSL::SSL::VERIFY_NONE if uri.scheme == 'https' && uri.host == '127.0.0.1' 
						res = http.request(req)

						puts "pinging rails server with URI #{uri.to_s}, response body:\n#{res.body}"
					rescue Exception => e
						puts "\nException: #{e} while pinging rails with URI: #{uri.to_s}"
					end ## end try
				end
			end
		
	end
end