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

# Fly me to the moon, let me dance among the stars...
class Events < Sinatra::Base

  # This function contains code common to all endpoints: JSON extraction, setting up some instance variables, and checking verification tokens (for security)
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
      # the payload might be URI encoded. Partly. Seriously. We'll need to try again. This happens for message actions webhooks only
      begin
        body = body.split('payload=', 2)[1]
        @request_data = JSON.parse(URI.decode(body))
      rescue JSON::ParserError => e
        halt 419, "Malformed event payload"
      end
    end

    # What team generated this event?
    @team_id = @request_data['team_id']
    # maybe this is a message action, in which case we have to dig deeper. This is one place where the Slack API is maddeningly inconsistent
    @team_id = @request_data['team']['id'] if @team_id.nil? && @request_data['team']

    # Load up the Slack application tokens for this team and put them where we can reach them.
    @token = $tokens.find({team_id: @team_id}).first

    # Check the verification token provided with the request to make sure it matches the verification token in
    # your app's setting to confirm that the request came from Slack.
    unless SLACK_CONFIG[:slack_verification_token] == @request_data['token']
      halt 403, "Invalid Slack verification token received: #{@request_data['token']}"
    end
  end

  # This cool function allows us to write Sinatra endpoints for individual events of interest directly! How fun! Magic!
  set(:event) do |value|
    condition do
      # Each Slack event has a unique `type`. The `message` event also has a `subtype`, sometimes, that we can capture too.
      # Let's make message subtypes look like `message.subtype` for convenience
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

####################################
# helper functions
#

  # This method takes a `message` event that should be indexed, extracts all the links in that message, opens each of those
  # links (asynchronously of course!), flattens the HTML into plaintext, and send that on to Algolia for indexing.
  def index message
    # We begin the hunt for links. The good news is that Slack marks them out for us!
    # Links look like:
    # <http://google.com>
    # or
    # <http://google.com|Google!>
    # We want to ignore the label, and just get the URL
    links = []
    message['text'].scan(/<(https?:\/\/.+?)>/).each do |m|
      url = m[0].split('|')[0]
      links.append url
    end

    links.each do |link|
      Unirest.get link do |response|
        # We are now in our own thread, operating asynchronously. We can take our time here.

        # First, we use Nokogiri to extract the page body, and flatten it to plaintext, removing any CSS, JS, or links that we really don't want in the index.
        page = Nokogiri::HTML(response.body)
        page.css('script, link, style').each { |node| node.remove }
        text = page.css('body').text
        title = page.css('title').text

        index = Algolia::Index.new(@request_data['team_id'])

        # And we index it.
        # The Algolia docs say 10KB, but I'm going to round down in the name of keeping things simple and truncate any webpage to 9000 characters
        # We are doing this sync, because a) we're already in a background thread, and b) when we're done, we're going to add a reacji to the message to show
        # it has been indexed!
        res = index.add_object!({title: title, body: text.truncate(9000), link: link, ts: message['ts']}, link)
        if res
          # Upon success, let's let the user know by adding a reactji to their message
          client = create_slack_client(@token['bot_access_token'])
          client.reactions_add name: 'flashlight', channel: message['channel'], timestamp: message['ts']
        end
      end
    end
  end




  # This method take a search query string, executes it, and returns a message object that can be sent on to Slack for rendering.
  def query query_str, page=0

    # We begin by searching!
    index = Algolia::Index.new(@team_id)
    res = index.search(query_str, {'attributesToRetrieve' => ['link', 'title'], 'page' => page, 'hitsPerPage' => 5})

    # Now, let's set up a response that looks like this:
    # https://api.slack.com/docs/messages/builder?msg=%7B%22text%22%3A%22http%3A%2F%2Fgoogle.com%5Cnhttp%3A%2F%2Fmedium.com%22%7D
    # Basically, we want to include all the links in the response, followed by pagination buttons if there are multiple pages, followed by a nice footer that respects the terms of the Algolia free plan

    if res['hits'].nil? or (res['hits'].size == 0)
      # not hits to return :( Let the user know they struck out.
      return {
          text: "I am sorry to say that I found no hits for \"#{query_str}\"",
          attachments: [{
                            'text': '',
                            'footer': 'Powered by Algolia',
                            'footer_icon': 'https://www.algolia.com/static_assets/images/press/downloads/algolia-mark-blue.png'
                        }]
      }

    else
      # we have hits to return!
      # We are just going to load all the links into the message text.
      text = 'I found some results for you.'
      res['hits'].each do |hit|
        # a bulleted list works great
        text = text+"\n  • <#{hit['link']}|#{hit['title'].strip}>"
      end

      # Slack has this notion of message attachments. They are a cool way to structure the message. Also, action buttons have to go into an attachment.
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

      # add an attachment for the Algolia Free Plan Terms Satisfaction
      footer = {
          text: '',
          footer: 'Powered by Algolia',
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

####################################
# Event handlers
#

  # See? I said it would be fun. Here is the endpoint for handling the necessary events endpoint url verification, which
  # is a one-time step in the application creation process. We have to do it :( Exactly once. But it's easy.
  post '/events', :event => 'url_verification' do
    return @request_data['challenge']
  end




  # Now things get a bit more exciting. Here is the endpoint for handling user messages! We need to determine whether to
  # index, run a query, or ignore the message, and then possibly render a response.
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

    # Does the message satisfy the rule above? Index it!
    if is_in_public_channel && !is_addressed_to_us
      index message
      halt 200
    end

    # The other rule is: If the message is meant for us, then run a query. A message meant for us is a message
    # that @-mentions us, or else arrives in a DM with us.
    if is_in_dm || is_addressed_to_us
      # Assume that the search query is following the @-mention
      # TODO maybe not an awesome interface for this bot?
      match = Regexp.new('(<@'+@token['bot_user_id']+'>:?)?(.*)').match message['text']
      query_str = match[2].strip

      # Run the response, and capture the resulting reply
      response = query query_str
      response[:channel] = message['channel']

      # Finally, post that reply back in the same channel that the query came from
      client = create_slack_client(@token['bot_access_token'])
      client.chat_postMessage response
    end

    # else, do nothing. Ignore the message.
    status 200
  end





  # Here is the endpoint for handling message actions
  # We end up here if someone clicked a button in one of our messages.
  # Since at the moment we only support prev and next buttons in query results, we don't need to do any special handling,
  # we are free to make a range of useful assumptions
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