# Manual Data Import Guide

## Issue Identified
The automatic import of `docs/old_data.sql` (15MB) is not completing successfully due to file size limitations when piping to the database container.

## Solution Options

### Option 1: Manual Import via Studio (Recommended)
1. Open Supabase Studio at: http://127.0.0.1:54323
2. Navigate to the SQL Editor
3. Copy the content from `docs/old_data.sql`
4. Execute the SQL in the editor
5. This will handle the large file size properly

### Option 2: Batch Import
Split the `docs/old_data.sql` into smaller files and import them separately.

### Option 3: Using PostgreSQL Client
Install a PostgreSQL client (like pgAdmin or DBeaver) and connect directly to:
- Host: 127.0.0.1
- Port: 54322
- Database: postgres
- User: postgres
- Password: postgres

Then execute the `docs/old_data.sql` file.

## Current Database Status
- **barang_units**: 6 records (expected: 75)
- **barang_prices**: 6 records
- **master_barang**: 5 records
- **locations**: 1 record
- **Total Expected**: 57,629 records
- **Currently Imported**: ~17,576 records

## Recommendation
Use **Option 1 (Manual Import via Studio)** for the most reliable import of your production data.