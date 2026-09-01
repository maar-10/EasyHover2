# Config-system overhaul — original brainstorm prompt (operator, 2026-09-01)

> Saved verbatim from the operator's message that kicked off the config-overhaul brainstorm.

Okay, while we figure out logging (buddy is working on it), you could dig into something else thats on my mind. The whole config system we have right now is pretty safe and solid. But its verbose and complicated. I want to bring robustness/security onto a common ground with ease of use. Right now, i think we have:

Shell tools to set all config on the fcs computer. Shell tools to set all config on the UI PC. The UI menus to config.

The configs that live on the fcs computer. The configs that live on the UI PC. The configs that live on a possible disk.

The option to sync the UI PC and the FCS to load UI PC config files into the FCS on FCS boot. The option to load its own config files (for 1 and 2) and the default tunings (for 3) on FCS boot. And the option to load from disk on FCS boot.

Also there is UI config for set monitors, UI bindings and UI settings.

And config for waypoints and routes on the NAV PC, aswell as channel config for GPS and some other settings.

Am i right on those/missing something?

This is very, VERY verbose. Its redundant and safe. But way to much hustle and trouble to keep track of, can lead to human error on loading/saving/overwriting files and is confusing at times.

Lets redesign this. We brainstorm it first, but my basic direction that i want to go is:

We only keep FCS config on the FCS PC. UI config on the UI PC. And NAV config on the NAV PC. Each role can only export/import to/from disk for its own role. FCS sync stays, but gets repurposed to check config rather than change.

We stop shipping ALL tools to all roles. I did ask for it on purpose. I accept that i was overly conservative and that this was a bad decision. We drop ALL tools that are used for FCS configs, from all other role shippings than FCS. We drop ALL tools for UI PC configs from all other roles than UI. And we drop ALL FCS and UI config tools from NAV and BEACON roles.

Then we stop any double writing, meaning all sources that write FCS config (wether the FCS roles tools, the UI menus for FCS configs (like FCS tuning, sensor calibration, devbinding, etc.) or disk imports) ONLY EVER write directly onto the FCS computer, creating or (most likely) overwriting the FCS configs. All sources that write UI configs only ever write to the UI PC. All sources that write NAV config only ever write to the NAV PC. This way, we only have A SINGLE config file for each config target on the whole wired network (+ the possible disk files).

All of this must always:

Be gated behind the comms hygiene.

Be gated behind the FCS mainThread convention.

This means, while we do potentionally write from UI to FCS now, it can only run when actively configuring. No constant streaming of data for configs.

The disk system needs the logic to only ever import/export files to the correct role. Meaning the main DTC menu on on the UI panel can import/export all 3 roles separately. When the disk gets called by the FCS on FCS boot up, it will only write FCS config to the FCS. When the UI PC imports/exports UI only configs it will only transfer UI configs. Same for NAV.

In addition, we need 2 more special options on the Suite/SuiteX. Under advanced. One option to merge the current existing config system to the new one, preventing loss of configs (if needed). And second, an option to flag current configs as DEFAULT and back them up separately from the update backup of the suites.

Then, the FCS, UI and NAV all get options to:

1. Load the DEFAULT configs.
2. Load the current configs.
3. Load from disk.

FCS and UI both have boot phases already, FCS for exactly this options, we just need to adjust them. UI for logging, we can expand. NAV needs a boot phase.
