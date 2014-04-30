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
				if hash_string && !hash_string.empty?
					# subscriptions = eval(hash_string)
					key = hash_string.find{|k, v| eval(v)[:client_id] == message['clientId']}
					if key
						Redis.current.hset('subscriptions', key.first, {time: Time.now.to_i, client_id: eval(hash_string[key.first])[:client_id]})
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
      if message["ext"]["private_pub_signature"] != subscription[:signature]
        message["error"] = "Incorrect signature."
      elsif PrivatePub.signature_expired? message["ext"]["private_pub_timestamp"].to_i
        message["error"] = "Signature has expired."
			else
				## begin try
				begin
					Redis.current.hset('subscriptions', message["subscription"], {time: Time.now.to_i, client_id: message['clientId']})
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
