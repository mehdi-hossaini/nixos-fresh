{
  inputs,
  user,
  fullName,
  email,
  ...
}:
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-bak";
    # sharedModules rather than an import inside modules/home: this is a module
    # *source*, not configuration, and it comes from a flake input that only
    # this file has `inputs` for.
    sharedModules = [
      inputs.plasma-manager.homeModules.plasma-manager
      # Ships the nix-locate database prebuilt. The nix-index package would build
      # it into ~/.cache/nix-index, which impermanence does not persist.
      inputs.nix-index-database.homeModules.nix-index
    ];
    extraSpecialArgs = {
      inherit
        inputs
        user
        fullName
        email
        ;
    };
    users.${user} = import ../home;
  };
}
