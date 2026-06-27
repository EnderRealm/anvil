# CLAUDE.md

## Project Overview

<!-- Describe your project here -->

## Ticket Management

Tickets are managed via the `plugin:forge:tk` MCP server. Use MCP tools (`ticket_list`, `ticket_create`, `ticket_advance`, `ticket_edit`, `ticket_review`, etc.) for all ticket operations. Never read or parse `.tickets/` files directly.

## Development Workflow

This project uses the forge plugin for stage-based development:
- `/idea` — capture new work into the backlog
- `/work-ticket <id>` — resume existing ticket at its current stage
- `/tk-ready` — see what's ready to work on

Pipeline stages: backlog → triage → spec → design → implement → test → verify → done

## Development Guidelines

<!-- Add your coding standards, architecture notes, etc. -->
