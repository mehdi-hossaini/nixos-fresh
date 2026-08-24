-- nixd was declared in packages.nix as VS Code's Nix language server, paired with
-- the nix-ide extension. VS Code is gone; the server is not, and a language server
-- with no client left is precisely the shape POST-INSTALL's closing section warns
-- about. So neovim inherits it.
--
-- mason = false because nixd comes from packages.nix and is already on PATH.
-- Without it LazyVim would ask mason to download a second copy, which on this
-- machine would be a prebuilt binary leaning on nix-ld to run at all.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        nixd = { mason = false },
      },
    },
  },
}
