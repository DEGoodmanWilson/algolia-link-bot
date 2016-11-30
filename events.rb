require 'sinatra/base'
require 'slack-ruby-client'
require 'mongo'
require 'algoliasearch'
require 'unirest'
require 'nokogiri'
require_relative 'helpers'

Algolia.init

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


  def index message

    # We begin the hunt for links. The good news is that Slack marks them out for us!
    # Links look like:
    # <http://google.com>
    # or
    # <http://google.com|Google!>
    # We want to ignore the label
    # This regex is a little janky, but it'll do for now
    links = []
    message['text'].scan(/<(https?:\/\/.+?)>/).each do |m|
      url = m[0].split('|')[0]
      links.append url
    end

    index = Algolia::Index.new(@request_data['team_id'])
    links.each do |link|
      Unirest.get link do |response|
        page = Nokogiri::HTML(response.body)
        # TODO This needs a some polish. Look at the results for https://slackhq.com/adventures-of-a-world-famous-librarian-b03135fe40a0#.8hdodu9qz
        page.css('script, link, style').each { |node| node.remove }
        text = page.css('body').text
        title = page.css('title').text

        index.add_object({title: title, body: text}, link)
      end
    end

    # client = create_slack_client(@token['bot_access_token'])
    # client.chat_postMessage(channel: message['channel'], as_user:true, text: links.to_s)


    # index.add_objects([message])
  end

  def query message
    client = create_slack_client(@token['bot_access_token'])
    client.chat_postMessage(channel: message['channel'], as_user:true, text: message['text'])
  end


  # Now things get a bit more excited. Here is the endpoint for handling user messages!
  post '/events', :event => 'message' do

    message = @request_data['event']

    # First of all, ignore all message originating from us
    return if message['user'] == @token['bot_user_id']


    # at this point, lots of things could happen.
    # This could be an ambient message that we should scan for links to index
    # Or this could be a message directed at _us_, in which case we should treat it as a search query.
    #  Note that we don't want to index either search queries, or anything _we_ post into the channel!


    # The rule we're going to use is this:
    # Index only messages a) not addressed to us and b) in a public channel

    # Now, is this message addressed to us?
    is_addressed_to_us = !Regexp.new('<@'+@token['bot_user_id']+'>').match(message['text']).nil?

    # Is it in a DM?
    is_in_dm = message['channel'][0] == 'D'

    # Is it in a public channel?
    is_in_public_channel = message['channel'][0] == 'C'


    if is_in_public_channel && !is_addressed_to_us
      index message
      halt 200
    end

    if is_in_dm || is_addressed_to_us
      query message
      halt 200
    end

    # else, do nothing. Ignore the message.
    status 200
  end
end