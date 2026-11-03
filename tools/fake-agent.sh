#!/bin/bash
# Fake coding agent for UI fixtures and screenshots (never calls a real model).
# usage: fake-agent.sh <working|input|done> [prompt text]
mode=${1:-working}; prompt=${2:-"snapshot should replay the main screen before the alt screen"}
o=$'\e[38;5;209m'; g=$'\e[32m'; r=$'\e[31m'; d=$'\e[90m'; b=$'\e[1m'; n=$'\e[0m'
printf '\e]2;%s\a' "$prompt"
printf '%s✻ %sFake Agent%s%s  %s%s\n\n' "$o" "$b" "$n" "$d" "$PWD" "$n"
printf '%s> %s%s\n\n' "$d" "$n" "$prompt"
printf '%s⏺ %s%sRead%s%s(core/crates/octomux/src/holder.rs)%s\n' "$g" "$n" "$b" "$n" "$d" "$n"
printf '%s  ⎿  Read 642 lines%s\n' "$d" "$n"
printf '%s⏺ %s%sUpdate%s%s(core/crates/octomux/src/holder.rs)%s\n' "$g" "$n" "$b" "$n" "$d" "$n"
printf '%s  ⎿  Updated with %s18 additions%s%s and %s4 removals%s\n' "$d" "$g" "$n" "$d" "$r" "$n"
printf '%s⏺ %s%sBash%s%s(cargo test -p octomux)%s\n' "$g" "$n" "$b" "$n" "$d" "$n"
printf '%s  ⎿  test result: %sok%s%s. 26 passed; 0 failed%s\n\n' "$d" "$g" "$n" "$d" "$n"
case $mode in
  working)
    printf '\e]7501;state=working:app=fake\a'
    printf '%s✶ Pondering… %s(14s · esc to interrupt)%s\n' "$o" "$d" "$n" ;;
  input)
    printf '\e]7501;state=blocked:app=fake\a'
    printf '%sAllow %sBash(git push)%s?%s\n  %s❯ 1. Yes%s\n    2. No, tell the agent what to do differently\n' "$b" "$o" "$n$b" "$n" "$o" "$n" ;;
  done)
    printf '\e]7501;state=done:app=fake\a'
    printf '⏺ The holder now captures the main screen on alt-screen entry and\n  replays it first, so reattaching inside vim keeps your shell.\n' ;;
esac
printf '\n%s╭──────────────────────────────────────────────╮%s\n%s│%s > %s\n%s╰──────────────────────────────────────────────╯%s\n' "$d" "$n" "$d" "$n" "" "$d" "$n"
exec cat >/dev/null
