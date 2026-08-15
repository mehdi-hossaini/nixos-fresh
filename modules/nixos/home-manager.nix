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
