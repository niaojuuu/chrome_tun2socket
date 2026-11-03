#!/bin/bash
args=(:1 -geometry "${RESOLUTION:-1600x900}" -depth 24 -rfbport 5901 -localhost
      -AlwaysShared -AcceptSetDesktopSize=0 -nolisten tcp
      -MaxCutText=10485760 -SendPrimary=0)  # 只同步明确复制的内容，单纯选中文字不算
if [ -f "$HOME/.vnc/passwd" ]; then
  args+=(-SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd")
else
  args+=(-SecurityTypes None)
fi
exec Xvnc "${args[@]}"
