-- LazyVim ships tokyonight. Everything else on this machine is gruvbox and the
-- palette is declared once in modules/home/palette.nix, which flake.nix asserts
-- contrast figures against — so the editor follows the machine rather than being
-- the one window that disagrees with the terminal it opens in.
--
-- Replaces the starter's lua/plugins/example.lua, which is 190 lines of commented
-- samples behind `if true then return {} end` and loads nothing. gruvbox.nvim is
-- the plugin that file suggests first.
return {
  { "ellisonleao/gruvbox.nvim", priority = 1000 },
  { "LazyVim/LazyVim", opts = { colorscheme = "gruvbox" } },
}
