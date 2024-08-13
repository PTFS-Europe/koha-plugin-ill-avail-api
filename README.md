# koha-plugin-ill-avail-api

This plugin provides ILL availability search results functionality coming from another Koha, using Koha's REST API.

## Installation

1. Install the plugin in your Koha instance.

2. Configure the Koha service host, REST user and REST password.

## Usage

1. ILLModule needs to be enabled
2. ILLCheckAvailability needs to be enabled
3. At least one backend is required
4. Create a new ILL request, enter metadata and press submit
5. Verify the ILL availability results coming from the configured Koha service