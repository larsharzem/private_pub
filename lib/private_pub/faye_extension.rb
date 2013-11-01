require 'redis'

module PrivatePub
  # This class is an extension for the Faye::RackAdapter.
  # It is used inside of PrivatePub.faye_app.
  class FayeExtension

		Redis.current = Redis.new(:host => '127.0.0.1', :port => 6379)
		
    # Callback to handle incoming Faye messages. This authenticates both
    # subscribe and publish calls.
    def incoming(message, callback)
			hash_string = Redis.current.hgetall('subscriptions')
			if hash_string && !hash_string.empty?
				# subscriptions = eval(hash_string)
				key = hash_string.find{|k, v| eval(v)[:client_id] == message['clientId']}
				if key
					Redis.current.hset('subscriptions', key.first, {time: Time.now.to_i, client_id: eval(hash_string[key.first])[:client_id]})
				end
			end
			# Redis.current.set(channel, client_id)
      if message["channel"] == "/meta/subscribe"
        authenticate_subscribe(message)
      elsif message["channel"] !~ %r{^/meta/}
        authenticate_publish(message)
      end
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
				Redis.current.hset('subscriptions', message["subscription"], {time: Time.now.to_i, client_id: message['clientId']})
				puts "\nPP redis hset: #{Redis.current.hgetall('subscriptions')}\n"
      end
    end

    # Ensures the secret token is correct before publishing.
    def authenticate_publish(message)
      if PrivatePub.config[:secret_token].nil?
        raise Error, "No secret_token config set, ensure private_pub.yml is loaded properly."
      elsif message["ext"]["private_pub_token"] != PrivatePub.config[:secret_token]
        message["error"] = "Incorrect token."
      else
        message["ext"]["private_pub_token"] = nil
      end
    end
  end
end
