# AGENTS.md

## Project Overview

<!-- Describe your project here -->

## Tickets

This project uses **tk** for task tracking — drive it via its MCP tools, never edit the
ticket store directly. Statuses: backlog → ready → open → done (closed = won't fix /
duplicate). Types: epic, feature, bug.

## Skills

- `/capture`     — create a well-formed ticket (why + success contract).
- `/work`        — drive a ticket from open to done (implement → review loop → commit → push).
- `/brainstorm`  — refine a rough idea into a concrete design, then hand off to /capture.
- `/investigate` — disciplined debugging when the cause isn't obvious.

## Git hygiene

One ticket = one commit = one push. Commit messages reference the ticket id as
`[<ticket-id>]`. Not done until committed and pushed.

## Development Guidelines

<!-- Add your coding standards, architecture notes, etc. -->
