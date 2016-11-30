require 'sinatra/base'
require 'slack-ruby-client'
require 'mongo'
require_relative 'helpers'


class Events < Sinatra::Base

  # This function contains code common to all endpoints: JSON extraction, and checking verification tokens
  before do
    # Extract the Event payload from the request and parse the JSON. We can reasonably assume this will be present
    begin
      @request_data = JSON.parse(request.body.read)
    rescue JSON::ParserError
      halt 419, "No event payload"
    end

    @token = $tokens.find({team_id: @request_data['team_id']}).first

    halt 419, "No token" if @token.nil?


    # Check the verification token provided with the requat to make sure it matches the verification token in
    # your app's setting to confirm that the request came from Slack.
    unless SLACK_CONFIG[:slack_verification_token] == @request_data['token']
      halt 403, "Invalid Slack verification token received: #{@request_data['token']}"
    end
  end

  # This cool function allows us to write Sinatra endpoints for individual events of interest directly! How fun!
  set(:event) do |value|
    condition do
      return true if @request_data['type'] == value

      if @request_data['type'] == 'event_callback'
        type = @request_data['event']['type']
        unless @request_data['event']['subtype'].nil?
          type = type + '.' + @request_data['event']['subtype']
        end
        return true if type == value
      end

      return false
    end
  end


  # See? I said it would be fun. Here is the endpoint for handling the necessayr events endpoint url verification, which
  # is a one-time step in the application creation process. We have to do it :(
  post '/events', :event => 'url_verification' do
    return @request_data['challenge']
  end

  # Now things get a bit more excited. Here is the endpoint for handling user messages!
  post '/events', :event => 'message' do

    # First of all, ignore all message originating from us
    return if @request_data['event']['user'] == @token['bot_user_id']

    puts @request_data
    puts @token

    client = create_slack_client(@token['bot_access_token'])
    client.chat_postMessage(channel: @request_data['event']['channel'], as_user:true, text: @request_data['event']['text'])

    # at this point, lots of things could happen.
    # This could be an ambient message that we should scan for links to index
    # Or this could be a message directed at _us_, in which case we should treat it as a search query.
    #  Note that we don't want to index either search queries, or anything _we_ post into the channel!
    status 200
  end

end