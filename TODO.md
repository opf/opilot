# TODO

OPilot's roadmap. See [README.md](README.md) for what the project already does.

## Productization
* Wire the agent into our Compose stack!
  * either via an override file or a separate branch/fork
* Point OPilot to our custom LLM
* Introduce proper UI!
  * AI chat noise deflected from the main activity comments
  * LLM working/typing indicator using HocusPocus
* Make the agent work off webhooks instead of constant polling

## Security & Hosting
* Switch from Docker to Podman for root-less process model
* Replace authgw with a configurable tiny proxy

## AI Architecture
* Set up token limits & cleanly handle threshold breaches
* Centralize our skill and agent definitions into another OP repo, so that OPilot may leverage them
  * Good candidate: https://github.com/opf/openproject-agent-skills
* Use more clear split between agent "personas" -- reviewer, developer etc.
* Try to compact token usage
  * Inspiration: https://andrewpatterson.dev/posts/token-savings-rtk-headroom/

## Feature ideas
* Matrix/Element integration, to track activity via a standalone channel
* Nextcloud integration, so that we can load relevant data during designs
* Figma integration, to interpret designs
* Explore ingestion of pictures & videos in WP description (and linked by Nextcloud)
* Transition the WP status & other fields when taking over implementation
* Generate arbitrary non-code artifacts like SVGs or stylesheets
  * For now, at least gists could be good enough for basic text reports
* Add a diagram that maps OPilot commands to complete product development flow (waterfall-ish)
* Move the adopt command into its own repo? 
* Consider running actual tests -- tricky, as they'd need to be run via the `docker compose` stack on the host system
  * There _are_ ways of giving the runner container access to Docker via a shared socket. However, this breaks the sandbox model, as it escalates the runner's permissions to run/access any containers on the host system.
  * Or just run OPilot in the same local network as the docker stack, then trigger commands via a HTTP API slapped into the main OP container
* Idea: Use sub-WPs for any OPilot interactions in agent mode
* Intent classification interface?
  * user issues a free-text prompt ("generate a PR pls") → a light model converts it to a "build" command
