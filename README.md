# WSL2 to Windows Godot LSP proxy

When using Neovim from WSL and Godot from Windows - the LSP file paths are not compatible

This is the simple TCP proxy that mirrors requests that LSP protocol does (JSON RPC), finds and replaces paths both ways: from linux to windows and from windows to linux

It works as a separate server that LSP Client from your editor should connect to

This project is inspired by [godot-wsl-lsp](https://github.com/lucasecdb/godot-wsl-lsp) and is a successor to [Python godot-wsl-proxy](https://github.com/venomlab/godot-wsl-proxy) but uses low-level memory-safe compiled language to perform proxying lightning-fast

# Installation

## With Pre-Built Binaries

Download the binary distributtion and SHA256 checksum

```shell
wget "https://github.com/venomlab/godot-wsl-proxy.zig/releases/download/latest/godot-wsl-proxy-$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]').tar.gz"
wget "https://github.com/venomlab/godot-wsl-proxy.zig/releases/download/latest/godot-wsl-proxy-$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]').tar.gz.sha256"
```

Validate the checksum

```shell
sha256sum -c "godot-wsl-proxy-$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]').tar.gz.sha256"
```

You should receive `OK` output from sha256 command

Then unpack the `.tar.gz` archive

```shell
tar -xvf "godot-wsl-proxy-$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]').tar.gz"
```

And now - install it somewhere within `PATH`. For example, `~/.local/bin/`

```shell
install godot-wsl-proxy ~/.local/bin/
```

## From Source Code

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

In future I may add this to Mason
