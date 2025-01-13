# WSL2 to Windows Godot LSP proxy

When using Neovim from WSL and Godot from Windows - the LSP file paths are not compatible

This is the simple TCP proxy that mirrors requests that LSP protocol does (JSON RPC), finds and replaces paths both ways: from linux to windows and from windows to linux

It works as a separate server that LSP Client from your editor should connect to

This project is inspired by [godot-wsl-lsp](https://github.com/lucasecdb/godot-wsl-lsp) and is a successor to [Python godot-wsl-proxy](https://github.com/venomlab/godot-wsl-proxy) but uses low-level memory-safe compiled language to perform proxying lightning-fast

# Installation

Currently, there is only one way.

First, pull the repo

```shell
git clone https://github.com/venomlab/godot-wsl-proxy.zig godot-wsl-proxy
```


Go inside a folder and compile it in a release mode


```shell
cd godot-wsl-proxy
zig build -Doptimize=ReleaseSafe
```

Then install it into your `.local/bin`

```shell
install zig-out/bin/godot-wsl-proxy ~/.local/bin -v
```

Later I'm going to do binary release, so, you can just download it and use already

Also, in future I plan to add this to Mason (for Neovim users)

# Neovim LSP Config

You can easily configure this via small customization of nvim-lspconfig

```lua
if os.getenv("WSL_DISTRO_NAME") ~= nil then -- Easy way to check if it is WSL or no
    require("lspconfig").gdscript.setup({
        on_attach = on_attach,              -- Your buffer on_attach function
        cmd = { "godot-wsl-proxy" },
    })
else
    require("lspconfig").gdscript.setup({
        on_attach = on_attach, -- Your buffer on_attach function
    })
end
```

