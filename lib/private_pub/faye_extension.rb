require 'redis'

module PrivatePub
  # This class is an extension for the Faye::RackAdapter.
  # It is used inside of PrivatePub.faye_app.
  class FayeExtension
	def initialize(redis_address = "")
		puts "initialize, address:"
		puts redis_address || '127.0.0.1'
		Redis.current = Redis.new(:host => redis_address || '127.0.0.1', :port => 6379)
		return self
	end
	
    # Callback to handle incoming Faye messages. This authenticates both
    # subscribe and publish calls.
    def incoming(message, callback)
		## begin try
		begin
			hash_string = Redis.current.hgetall('subscriptions')
			#Redis.current.hset('log', "#{Time.now.to_i}_inco", {called_method: "incoming", message: message, hash_string: hash_string})
			if hash_string && !hash_string.empty?
				key = hash_string.find{|k, v| eval(v)[:client_id] == message['clientId']}
				if key && key.first.index('/feed/actor') == 0
					Redis.current.hset('subscriptions', key.first, {time: Time.now.to_i, client_id: eval(hash_string[key.first])[:client_id], called_method: "incoming"})
				end
			end
		rescue Exception => e
			puts "\nException: #{e}\n"
		end
		## end try
			
      if message["channel"] == "/meta/subscribe"
        authenticate_subscribe(message)
      elsif message["channel"] !~ %r{^/meta/}
        authenticate_publish(message)
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
			## begin try
			begin
				Redis.current.hset('subscriptions', message["subscription"], {time: Time.now.to_i, client_id: message['clientId'], called_method: "authenticate_subscribe"})
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
		
  end
end
