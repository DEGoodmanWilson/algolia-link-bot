# Algolia Link Bot

Do you tire of losing links that you've shared with others in Slack? Slack's search functionality doesn't inspect the contents of links posted into channels, so it can be hard to track external links down. Algolia Link Bot can help.

[Install Algolia Link Bot](https://secure-fortress-69461.herokuapp.com/) to your Slack team, and then invite it into a channel. Any links shared in that channel will be automatically indexed by the bot. You know they've been indexed, because Algolia Link Bot reacts to your message with the flashlight emoji when the links in it have been indexed.

To search the links indexed by Algolia Link Bot, send your query with an @-mention, or just DM the bot. For example, you could type:
```
> hey @algolia-link-bot cool arduino projects
```
and Algolia Link Bot will search through all the links it's observed for "cool arduino projects"

## Features

Upon installation, Algolia Link Bot does nothing on its own. However, when you invite Algolia Link Bot into a channel, two things happen. First, it will begin ingesting links that it observes, feeding them into the Algolia search index machine. Second, it stands by ready to help query those indexed links.

Algolia is set to index on the link title and body. Searches look to the title before the body; ties are broken by choosing the most recently indexed link first. Typos are set to minimum. These settings are configure programatically, as new indexes are created for each team that installs, ensuring that there is a solid wall between two teams' data!
 
Future enhancements might also include indexing Google Documents, Dropbox files, and uploaded files—none of which the current Slack search functionality touches (except superficially).
 
## Installation
 
Visit https://secure-fortress-69461.herokuapp.com/ and click "Add to Slack". Choose the team to install it on, and…oh wait, there is no step three!
 
## Usage
 
You'll need to invite Algolia Link Bot into channels where you want it to index links. Note that the bot will not search through your channel history to index links already posted in a channel—it will only index links posted _after_ it has been invited in.
 
You can query the index by either @-mentioning Algolia Link Bot in a channel to which it belongs, or sending your queries via DM (without the @-mention). Algolia Link Bot will return up to 5 matches at a time; if there are more than 5 matches, the bot will display a carousel allowing you to page through the entire set of matches.
 
## Learn More
 
The source code is fully documented—start with `events.rb`, as this contains the core functionality. Most of the Algolia configuration, on the other hand, is done at install time, so look to `auth.rb` to see how installation works.