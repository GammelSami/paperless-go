---
title: Push to both GitHub and GitLab when told to push
author: Bearyjd
date: 2026-10-18
standing: true
---

## Decided
This repo has two remotes, GitHub and GitLab. When the user says "push", push `main` (and any tag) to both and confirm they match local. The user said so each time the agent asked "push to GitHub and GitLab?".

## Watch out
Still never push without the user saying so; commits stay local until then. GitHub pushes from this machine failed until `gh auth setup-git` is run. GitLab mirror token expiry silently stops F-Droid updates.

_Told to Claude in 2 past sessions here, most recently on Oct 1._
