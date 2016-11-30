# Algolia Link Bot

Do you tire of losing links that you've shared with others? Slack's search functionality doesn't inspect the contents of links posted into channels. Algolia Link Bot can help.

Install Algolia Link Bot, and then invite it into a channel. Any links shared in that channel will be automatically indexed by the bot.

To search the links indexed by Algolia Link Bot, send your query with an @-mention, or just DM the bot. For example, you could type:
```
> hey @algolia-link-bot cool arduino projects
```
and Algolia Link Bot will search through all the links it's observed for "cool arduino projects"

## Features

Upon installation, Algolia Link Bot does nothing on its own. However, when you invite Algolia Link Bot into a channel, two things happen. First, it will begin ingesting links that it observes, feeding them into the Algolia search index machine. Second, it stands by ready to help query those indexed links.
 
Future enhancements might also include indexing Google Documents, Dropbox files, and uploaded files—none of which the current Slack search functionality touches (except superficially).
 
## Installation
 
Visit https://secure-fortress-69461.herokuapp.com/ and click "Add to Slack". Choose the team to install it on, and…oh wait, there is no step three!
 
## Usage
 
You'll need to invite Algolia Link Bot into channels where you want it to index links. Note that the bot will not search through your channel history to index links already posted in a channel—it will only index links posted _after_ it has been invited in.
 
You can query the index by either @-mentioning Algolia Link Bot in a channel to which it belongs, or sending your queries via DM (without the @-mention).
 
## Learn More
 
The source code is fully documented—start with `events.rb`, as this contains the core functionality.