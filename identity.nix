# Who this configuration belongs to. Machine-independent by definition — the
# same person installs on every host — so it lives here rather than in hosts/,
# and flake.nix threads it into every module through specialArgs.
#
# This and hosts/ are the only two places to edit when adopting this config.
{
  user = "mehti";
  fullName = "mehti";
  email = "littlemehti@gmail.com";
}
