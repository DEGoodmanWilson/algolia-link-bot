require 'sinatra/base'
require 'slack-ruby-client'
require 'mongo'
require_relative 'helpers'

# This code is largely borrowed from the Slack Ruby Events API example here https://github.com/slackapi/Slack-Ruby-Onboarding-Tutorial

db_client = Mongo::Client.new(ENV['MONGODB_URI'])
$tokens = db_client[:token]

# Load Slack app info into a hash called `config` from the environment variables assigned during setup
# See the "Running the app" section of the README for instructions.
SLACK_CONFIG = {
    slack_client_id: ENV['SLACK_CLIENT_ID'],
    slack_api_secret: ENV['SLACK_API_SECRET'],
    slack_redirect_uri: ENV['SLACK_REDIRECT_URI'],
    slack_verification_token: ENV['SLACK_VERIFICATION_TOKEN']
}

# Check to see if the required variables listed above were provided, and raise an exception if any are missing.
missing_params = SLACK_CONFIG.select { |key, value| value.nil? }
if missing_params.any?
  error_msg = missing_params.keys.join(", ").upcase
  raise "Missing Slack config variables: #{error_msg}"
end

# Set the OAuth scope of your bot. We're just using `bot` for this demo, as it has access to
# all the things we'll need to access. See: https://api.slack.com/docs/oauth-scopes for more info.
# In fact, we're going to add `channels:history` so we can preload some of the Algolia index! Normally
# this is anything but a best-practice, but it helps for this demo.
BOT_SCOPE = 'bot,channels:history'

# Slack uses OAuth for user authentication. This auth process is performed by exchanging a set of
# keys and tokens between Slack's servers and yours. This process allows the authorizing user to confirm
# that they want to grant our bot access to their team.
# See https://api.slack.com/docs/oauth for more information.
class Auth < Sinatra::Base
  # This is the HTML markup for our "Add to Slack" button.
  # Note that we pass the `client_id`, `scope` and "redirect_uri" parameters specific to our application's configs.
  add_to_slack_button = %(
    <a href=\"https://slack.com/oauth/authorize?scope=#{BOT_SCOPE}&client_id=#{SLACK_CONFIG[:slack_client_id]}&redirect_uri=#{SLACK_CONFIG[:slack_redirect_uri]}\">
      <img alt=\"Add to Slack\" height=\"40\" width=\"139\" src=\"https://platform.slack-edge.com/img/add_to_slack.png\"/>
    </a>
  )

  # If a user tries to access the index page, redirect them to the auth start page
  get '/' do
    redirect '/begin_auth'
  end

  # OAuth Step 1: Show the "Add to Slack" button, which links to Slack's auth request page.
  # This page shows the user what our app would like to access and what bot user we'd like to create for their team.
  get '/begin_auth' do
    status 200
    body add_to_slack_button
  end

  # OAuth Step 2: The user has told Slack that they want to authorize our app to use their account, so
  # Slack sends us a code which we can use to request a token for the user's account.
  get '/finish_auth' do
    client = Slack::Web::Client.new
    # OAuth Step 3: Success or failure
    begin
      response = client.oauth_access(
          {
              client_id: SLACK_CONFIG[:slack_client_id],
              client_secret: SLACK_CONFIG[:slack_api_secret],
              redirect_uri: SLACK_CONFIG[:slack_redirect_uri],
              code: params[:code] # (This is the OAuth code mentioned above)
          }
      )
      # Success:
      # Yay! Auth succeeded! Let's store the tokens and create a Slack client to use in our Events handlers.
      # The tokens we receive are used for accessing the Web API, but this process also creates the Team's bot user and
      # authorizes the app to access the Team's Events.

      # TODO this doesn't account for multiple installations; the problem is we are always overwrite the bearer token
      # with the token for the latest installer. This is no good. We should be more discerning! Most bots won't care
      # about this fact in the least, but since we are adding `channels:history` to our scope, we need to care about
      # the bearer tokens.
      # For now, however, this will do.
      team_id = response['team_id']
      doc = {
          team_id: team_id,
          user_access_token: response['access_token'],
          bot_user_id: response['bot']['bot_user_id'],
          bot_access_token: response['bot']['bot_access_token']
      }

      $tokens.find(team_id: team_id).replace_one(doc)

      # Post a message into the installer's channel
      installer = response['user_id']
      client = create_slack_client(response['bot']['bot_access_token'])
      client.chat_postMessage(channel: installer, as_user:true, text: "Hello <@#{installer}>! Thanks for installing me. Just invite me into any channel, and I will start indexing links that people post there. Message me to search through those links!")


      # Be sure to let the user know that auth succeeded.
      status 200
      body "Yay! Auth succeeded! You're awesome!"
    rescue Slack::Web::Api::Error => e
      # Failure:
      # D'oh! Let the user know that something went wrong and output the error message returned by the Slack client.
      status 403
      body "Auth failed! Reason: #{e.message}<br/>#{add_to_slack_button}"
    end
  end
end
