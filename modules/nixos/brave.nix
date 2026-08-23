# Browser policy. Brave reads managed policies from a compiled-in path: grepping
# opt/brave.com/brave-origin/brave in the package finds both /etc/brave/policies
# and /etc/chromium/policies. A JSON file dropped there is applied at startup and
# cannot be undone from the browser UI — which is the same bargain as every other
# rule here. Declared, or not at all.
{ ... }:
{
  # ActivityWatch's browser watcher (modules/home/default.nix runs the server).
  # Without it the timeline records Brave as one opaque `brave-origin` block,
  # which on this machine is the single biggest blind spot in the data: awatcher
  # can name the window but has no idea which tab is in front of it.
  #
  # Force-installed rather than merely allowed, so a machine rebuilt from this
  # repo arrives with it instead of needing a visit to the Web Store. The cost is
  # the honest one: it cannot be removed from brave://extensions, and turning it
  # off means deleting these lines and switching.
  #
  # The id was verified against the very endpoint this policy hands to Brave —
  # clients2.google.com/service/update2/crx resolves it to a real crx, while a
  # deliberately bogus id returns 404 there, so the check discriminates rather
  # than always passing. That mattered: extension ids are opaque strings, and a
  # wrong one fails by installing nothing at all, with no error anywhere.
  environment.etc."brave/policies/managed/activitywatch.json".text = builtins.toJSON {
    ExtensionInstallForcelist = [
      "nglaklhklhcoonedhgnpgddginnjdadi;https://clients2.google.com/service/update2/crx"
    ];
  };
}
