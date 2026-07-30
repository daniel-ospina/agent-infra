# TypeScript Security Patterns

## Type Safety Limitations

**Types don't validate at runtime:**

TypeScript interfaces and types are compile-time only. They provide no runtime protection:

```typescript
// UNSAFE: TypeScript says this is a string, but at runtime it could be anything
interface UserInput {
  name: string;
  email: string;
}

// The cast doesn't validate — attacker can send anything
const input = req.body as UserInput;

// SAFE: Use zod or similar for runtime validation
const UserInputSchema = z.object({
  name: z.string().min(1).max(100),
  email: z.string().email(),
});
const input = UserInputSchema.parse(req.body);
```

## strictNullChecks Patterns

**Non-null assertions (`!`) should be justified:**

With `strictNullChecks: true`, the `!` operator bypasses null safety:

```typescript
// SUSPICIOUS: Why are we asserting non-null?
const user = getUser()!;

// ACCEPTABLE: Guard is above, assertion is justified
if (!getUser()) throw new Error('No user');
const user = getUser()!;

// BEST: Use optional chaining or proper narrowing
const user = getUser();
if (!user) return;
// user is narrowed to non-null here
```

## Supabase Query Patterns

**`as any` casts on Supabase queries — expected, not a security issue:**

```typescript
// This pattern is standard in El Dato — .select() uses raw strings
// TypeScript can't validate column names, so casts are necessary
const { data } = await (supabase as any)
  .from('businesses')
  .select('id, name, slug')
  .eq('slug', slug);
```

Do NOT flag these as security issues. They are a known limitation of the Supabase JS SDK's typing.

**However, DO flag:**

```typescript
// DANGEROUS: User input directly interpolated into query
const { data } = await supabase
  .from('deals')
  .select(`*, ${userInput}`);  // SQL injection risk

// SAFE: Supabase SDK parameterizes .eq(), .in(), .filter() automatically
const { data } = await supabase
  .from('deals')
  .eq('category', userInput);  // Parameterized
```

## @ts-expect-error Comments

**Must describe the root cause:**

```typescript
// BAD: Uninformative
// @ts-expect-error
return ReactNodeViewRenderer(Component);

// GOOD: Explains the actual issue
// @ts-expect-error tiptap ReactNodeViewRenderer has narrow generic constraints
return ReactNodeViewRenderer(Component);
```

## Framework-Mitigated Patterns (Do NOT Flag)

| Pattern | Why Safe |
|---------|----------|
| `{variable}` in JSX | React auto-escapes interpolated values |
| React raw HTML injection (dangerouslySet*) with sanitized input | Flag ONLY if input is not sanitized |
| `href={userUrl}` | Flag ONLY `javascript:` protocol URLs |
| Supabase `.eq()`, `.in()`, `.filter()` | SDK parameterizes these automatically |
