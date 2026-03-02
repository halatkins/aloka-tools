# Companah DB Dashboard

Internal admin toolset for managing the Companah Supabase database (Project: Aloka).

## Tools

| File | Description |
|------|-------------|
| `index.html` | **Dashboard** — Hub page with database stats, schema overview, and links to all tools |
| `companah-schema-manager.html` | **Schema Manager** — Browse table structures, view columns/types/FKs, run SQL queries |
| `companah-data-manager.html` | **Data Manager** — Full CRUD (create, read, update, delete) for all 25 tables across 9 schemas |
| `companah-migration-tool.html` | **Migration Tool** — 4-step wizard to import data from Airtable into Supabase |
| `companah-db-guide.html` | **Database Guide** — Interactive visual guide to how the database is structured and how tables connect |
| `companah-supabase-migration.sql` | **Migration SQL** — The complete SQL script to create all schemas, tables, indexes, and triggers |
| `companah-supabase-schema.md` | **Schema Doc** — The master architecture document (source of truth for all design decisions) |

## Database Architecture

9 Postgres schemas, 25 tables:

- **core** — Organizations, contacts, pets (shared across all apps)
- **pricing** — Product catalog, partner wholesale rates
- **orders** — Cremation orders, line items, care plans, memorials
- **operations** — Cremation machines (Donatello, Michelangelo, Leonardo), processing runs
- **billing** — QBO invoices and line items
- **workflows** — Task templates, tasks, comments
- **partners** — Vet partner profiles and referrals
- **clients** — Portal access and review tracking
- **logistics** — Locations, routes, stops, stop items

## Getting Started

1. **Create the database tables**: Copy the contents of `companah-supabase-migration.sql` into the Supabase SQL Editor (Dashboard → SQL Editor → New Query) and run it.

2. **Open the dashboard**: Navigate to `index.html` in your browser, enter your Supabase project URL and service_role key, and connect.

3. **Migrate data** (optional): Use the Migration Tool to pull existing data from Airtable into the new Supabase tables.

## Hosting

These are static HTML files with no server-side dependencies. They connect directly to Supabase via its REST API. Host anywhere that serves static files — GitHub Pages, Vercel, Netlify, or any web server.

**Important**: These tools require a Supabase service_role key for full access. Keep the hosting environment access-restricted (private repo for GitHub Pages, basic auth, or internal network only).

## Supabase Project

- **Project name**: Aloka
- **Project URL**: `https://qrnjwdbqzeqtcyzwljvu.supabase.co`

## Tech Stack

- Plain HTML, CSS, JavaScript (no build step, no frameworks)
- Supabase PostgREST API for all database operations
- Airtable REST API for migration reads
