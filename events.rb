require 'sinatra/base'
require 'slack-ruby-client'
require 'mongo'
require 'algoliasearch'
require 'unirest'
require 'nokogiri'
require 'uri'
require 'json'
require_relative 'helpers'

Algolia.init

class Events < Sinatra::Base

  # This function contains code common to all endpoints: JSON extraction, and checking verification tokens
  before do
    body = request.body.read

    # Extract the Event payload from the request and parse the JSON. We can reasonably assume this will be present
    error = false
    begin
      @request_data = JSON.parse(body)
    rescue JSON::ParserError
      error = true
    end

    if error
      # the payload might be URI encoded. Partly. Seriously. We'll need to try again.
      begin
        body = body.split('payload=', 2)[1]
        @request_data = JSON.parse(URI.decode(body))
      rescue JSON::ParserError => e
        halt 419, "Malformed event payload"
      end
    end

    @team_id = @request_data['team_id']
    #maybe this is a message action, in which case we have to dig deeper
    @team_id = @request_data['team']['id'] if @team_id.nil?

    @token = $tokens.find({team_id: @team_id}).first

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

        index.add_object({title: title, body: text, link: link, ts: message['ts']}, link)
      end
    end
  end

  def query query_str, page=0
    index = Algolia::Index.new(@team_id)

    res = index.search(query_str, {'attributesToRetrieve' => ['link', 'title'], 'page' => page, 'hitsPerPage' => 5})

    # Now, let's set up a response that looks like this:
    # https://api.slack.com/docs/messages/builder?msg=%7B%22text%22%3A%22http%3A%2F%2Fgoogle.com%5Cnhttp%3A%2F%2Fmedium.com%22%7D

    if res['hits'].nil? or (res['hits'].size == 0)
      # not hits to return :(
      return {
          text: "I am sorry to say that I found no hits for \"#{query_str}\"",
          attachments: [{
                            'text': '',
                            'footer': 'Powered by Aloglia',
                            'footer_icon': 'https://www.algolia.com/static_assets/images/press/downloads/algolia-mark-blue.png'
                        }]
      }

    else
      # we have hits to return!
      # We are just going to load all the links into the text string, and let Slack take care of unfurling those links
      # into something beautiful
      text = "I found some results for you."
      res['hits'].each do |hit|
        text = text+"\n  • <#{hit['link']}|#{hit['title'].strip}>"
      end

      attachments = []
      buttons = []

      # Now we need to determine whether we should add buttons or not.

      #First, let's see if we should add a previous button. This is easy: Is the current page > 0? Then we need a prev button
      if res['page'] > 0
        p_button = {
            name: 'prev',
            text: 'Prev',
            type: 'button',
            value: res['page']-1
        }
        buttons.append p_button
      end

      #Now, a next button. If page is < nbPages, add a next button
      # We subtract one because of zero indexing.
      if res['page'] < (res['nbPages']-1)
        n_button = {
            name: 'next',
            text: 'Next',
            type: 'button',
            value: res['page']+1
        }
        buttons.append n_button
      end

      # Now, add any buttons we created to an attachment, if indeed there are any
      unless buttons.empty?
        buttons_attachment = {
            text: "Page #{res['page']+1} of #{res['nbPages']}",
            fallback: 'You cannot use message actions here',
            callback_id: query_str,
            attachment_type: 'default',
            actions: buttons
        }
        attachments.append buttons_attachment
      end

      # add an attachment for the credits
      footer = {
          text: '',
          footer: 'Powered by Aloglia',
          footer_icon: 'https://www.algolia.com/static_assets/images/press/downloads/algolia-mark-blue.png'
      }
      attachments.append footer

      return {
          text: text,
          unfurl_links: false,
          unfurl_media: false,
          attachments: attachments
      }
    end
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
      # Assume that the search query is following the @-mention
      # TODO maybe not an awesome interface for this bot?
      match = Regexp.new('(<@'+@token['bot_user_id']+'>:?)?(.*)').match message['text']
      query_str = match[2].strip

      response = query query_str
      response[:channel] = message['channel']

      client = create_slack_client(@token['bot_access_token'])
      client.chat_postMessage response
    end

    # else, do nothing. Ignore the message.
    status 200
  end

  # Here is the endpoint for handling message actions
  # We end up here if someone clicked a button in one of our messages.
  # Since at the moment we only support prev and next buttons in query results, we don't need to do any special handling
  post '/buttons' do

    # So, someone hit "prev" or "next". Our job is to figure out
    # a) what they were looking at and
    # b) where they want to go
    # c) and then reconstruct the message with the new data

    query_str = @request_data['callback_id'] # we stored the query in the callback id, so clever!
    new_page = @request_data['actions'][0]['value'].to_i # and the new page to fetch here.

    #we have enough to run the query!
    response = query query_str, new_page

    # Rather than posting a new message, we'll just respond with the new message to replace the old message! It's like a carousel
    content_type :json
    response.to_json
  end
end