require 'redis'

module PrivatePub
	# This class is an extension for the Faye::RackAdapter.
	# It is used inside of PrivatePub.faye_app.
	class FayeExtension
		def initialize(redis_address = "", redis_port = 6379, redis_password = nil)
			puts "initialize faye extension, address: #{redis_address || '127.0.0.1'}, port: #{redis_port}"
			if redis_password.present?
				Redis.current = Redis.new(host: redis_address || '127.0.0.1', port: redis_port, password: redis_password)
			else
				Redis.current = Redis.new(host: redis_address || '127.0.0.1', port: redis_port)
			end
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
				#Redis.current.hset('log', "#{Time.now.to_i}_auth", {called_method: "authenticate_subscribe", message_subscription: message["subscription"], client_id: message['clientId']})
				if message["ext"]["private_pub_signature"] != subscription[:signature]
					message["error"] = "Incorrect signature."
				elsif PrivatePub.signature_expired? message["ext"]["private_pub_timestamp"].to_i
					message["error"] = "Signature has expired."
				elsif message["subscription"].index('/feed/actor') == 0
				
					current_subsciptions = Redis.current.hgetall('subscriptions')
					present_subscription = current_subsciptions[message["subscription"]]
					puts "already present sub? #{present_subscription}"
					if present_subscription
						client_ids = eval(present_subscription)[:client_ids]
						client_ids[message['clientId']] = Time.now.to_i
					else
						client_ids = {message['clientId'] => Time.now.to_i}
					end
					## begin try
					begin
						puts "writing sub: #{client_ids}"
						Redis.current.hset('subscriptions', message["subscription"], {time: Time.now.to_i, client_ids: client_ids, called_method: "authenticate_subscribe"})
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
					puts "current_subsciptions: #{current_subsciptions}"
					#Redis.current.hset('log', "#{Time.now.to_i}_inco", {called_method: "incoming", message: message, current_subsciptions: current_subsciptions})
					
					return unless current_subsciptions
					message_client_id = message['clientId']
					key = current_subsciptions.find{|k, v| eval(v)[:client_ids] != nil && eval(v)[:client_ids][message_client_id]}
					puts "this user's subscription:   #{key ? key.first + " --> " + key.last : "NONE"}"
					
					return unless key && key.first.index('/feed/actor') == 0
					channel = key.first
					channel_hash = eval(current_subsciptions[channel])
					if message['channel'] == '/meta/disconnect'
						if channel_hash[:client_ids].length > 1
							puts "disconnect, deleting one client id #{message_client_id}, setting new timestamp: #{Time.now.to_i}"
							channel_hash[:time] = Time.now.to_i
							channel_hash[:called_method] = "incoming"
							channel_hash[:client_ids].delete(message_client_id)
							Redis.current.hset('subscriptions', channel, channel_hash)
						else
							puts "disconnect, deleting user's channel"
							Redis.current.hdel('subscriptions', channel)
						end
					else
						channel_hash[:time] = Time.now.to_i
						channel_hash[:called_method] = "incoming"
						channel_hash[:client_ids] = cleanup_client_id_timestamps(channel_hash[:client_ids], message_client_id)
						
						puts "updating timestamps for subscription of channel #{channel}: #{channel_hash}"
						Redis.current.hset('subscriptions', channel, channel_hash)
					end # don't do anything for /meta/unsubscribe
							
				rescue Exception => e
					puts "\nException: #{e}\n"
				end ## end try
			end
			
			def cleanup_client_id_timestamps(client_ids, current_client_id)
				client_ids.each do |client_id, timestamp|
					if client_id == current_client_id
						puts "found id, updating: #{client_id}"
						client_ids[client_id] = Time.now.to_i
					elsif Time.now.to_i - timestamp > 50 # 2 * the keep alive time
						puts "deleting: #{client_id}"
						client_ids.delete(client_id)
					end
				end
				
				return client_ids
			end
		
	end
end
