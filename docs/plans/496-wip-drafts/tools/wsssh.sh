#!/usr/bin/env bash
exec ssh -F "$HOME/.ssh/config" -T -o BatchMode=yes winsma '"C:\Program Files\Git\bin\bash.exe" -l -s'
