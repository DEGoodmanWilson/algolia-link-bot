require 'slack-ruby-client'

# Since we're going to create a Slack client object for each team, this helper keeps all of that logic in one place.
def create_slack_client(slack_api_secret)
  Slack.configure do |config|
    config.token = slack_api_secret
    fail 'Missing API token' unless config.token
  end
  Slack::Web::Client.new
end


# A method to truncate a string!
class String
  def truncate(max)
    length > max ? "#{self[0...max]}..." : self
  end
end