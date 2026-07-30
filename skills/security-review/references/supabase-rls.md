# Supabase RLS & Database Security Patterns

## SECURITY DEFINER Functions

**CRITICAL: GRANT EXECUTE required**

`SECURITY DEFINER` functions called via `supabase.rpc()` with service_role key need explicit grants:

```sql
-- WRONG: function exists but service_role can't call it
CREATE OR REPLACE FUNCTION public.my_function(...)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$ ... $$;

-- CORRECT: explicit grant
GRANT EXECUTE ON FUNCTION public.my_function TO service_role;
```

**Always SET search_path:**

```sql
CREATE OR REPLACE FUNCTION public.my_function(...)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''  -- Prevent search_path injection
AS $$ ... $$;
```

## auth.uid() Patterns

**NULL safety for service_role calls:**

`auth.uid()` returns NULL when called from service_role context. Guard patterns must be NULL-safe:

```sql
-- SAFE: NULL <> NULL evaluates to NULL (not TRUE), so guard doesn't fire for service_role
IF p_user_id <> auth.uid() THEN
  RETURN;
END IF;
```

**RLS performance — wrap in SELECT:**

```sql
-- SLOW: auth.uid() called per row
CREATE POLICY orders_policy ON orders
  USING (auth.uid() = user_id);

-- FAST: called once, cached
CREATE POLICY orders_policy ON orders
  USING ((SELECT auth.uid()) = user_id);
```

## Common Pitfalls

**array_agg() returns NULL, not empty array:**

```sql
-- WRONG: assumes empty array
SELECT array_agg(tag) FROM tags WHERE deal_id = $1;
-- Returns NULL when no rows match

-- CORRECT: always COALESCE
SELECT COALESCE(array_agg(tag), '{}') FROM tags WHERE deal_id = $1;
```

**RETURN QUERY does NOT set FOUND:**

```sql
-- WRONG: FOUND is always FALSE after RETURN QUERY
RETURN QUERY SELECT * FROM deals WHERE id = p_id;
IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;

-- CORRECT: pre-check with PERFORM
PERFORM 1 FROM deals WHERE id = p_id;
IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
RETURN QUERY SELECT * FROM deals WHERE id = p_id;
```

**Supabase .select() uses raw strings:**

TypeScript cannot validate column names at compile time. A typo in `.select('naem')` silently returns null columns. Always verify column names against the schema.

## QR Token Security

- QR tokens must be UUIDs — reject non-UUID formats before database lookup
- Verify token ownership via `business_users` join before granting access
- Never expose token values in URLs visible to end users (use one-time-use tokens)
