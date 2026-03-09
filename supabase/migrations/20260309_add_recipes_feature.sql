-- Recipes feature: creation, visibility, likes, and aggregated metrics.

create extension if not exists pgcrypto;

create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.recipes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  description text,
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.recipe_items (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.recipes(id) on delete cascade,
  product_code text not null references public.products(code),
  grams numeric(10,2) not null check (grams > 0),
  position int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.recipe_likes (
  recipe_id uuid not null references public.recipes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (recipe_id, user_id)
);

create index if not exists recipes_owner_idx on public.recipes(owner_id);
create index if not exists recipes_public_created_idx on public.recipes(is_public, created_at desc);
create index if not exists recipe_items_recipe_idx on public.recipe_items(recipe_id);
create index if not exists recipe_items_product_idx on public.recipe_items(product_code);
create index if not exists recipe_likes_recipe_idx on public.recipe_likes(recipe_id);
create index if not exists recipe_likes_user_idx on public.recipe_likes(user_id);

-- Keep recipe updated_at in sync on edits.
drop trigger if exists set_recipes_updated_at on public.recipes;
create trigger set_recipes_updated_at
before update on public.recipes
for each row
execute function public.tg_set_updated_at();

alter table public.recipes enable row level security;
alter table public.recipe_items enable row level security;
alter table public.recipe_likes enable row level security;

-- Recipes visibility: everyone can read public recipes, and owners can read their private ones.
drop policy if exists recipes_select_policy on public.recipes;
create policy recipes_select_policy
on public.recipes
for select
using (is_public = true or owner_id = auth.uid());

drop policy if exists recipes_insert_policy on public.recipes;
create policy recipes_insert_policy
on public.recipes
for insert
to authenticated
with check (owner_id = auth.uid());

drop policy if exists recipes_update_policy on public.recipes;
create policy recipes_update_policy
on public.recipes
for update
to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

drop policy if exists recipes_delete_policy on public.recipes;
create policy recipes_delete_policy
on public.recipes
for delete
to authenticated
using (owner_id = auth.uid());

-- Recipe items follow parent recipe access.
drop policy if exists recipe_items_select_policy on public.recipe_items;
create policy recipe_items_select_policy
on public.recipe_items
for select
using (
  exists (
    select 1
    from public.recipes r
    where r.id = recipe_items.recipe_id
      and (r.is_public = true or r.owner_id = auth.uid())
  )
);

drop policy if exists recipe_items_insert_policy on public.recipe_items;
create policy recipe_items_insert_policy
on public.recipe_items
for insert
to authenticated
with check (
  exists (
    select 1
    from public.recipes r
    where r.id = recipe_items.recipe_id
      and r.owner_id = auth.uid()
  )
);

drop policy if exists recipe_items_update_policy on public.recipe_items;
create policy recipe_items_update_policy
on public.recipe_items
for update
to authenticated
using (
  exists (
    select 1
    from public.recipes r
    where r.id = recipe_items.recipe_id
      and r.owner_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from public.recipes r
    where r.id = recipe_items.recipe_id
      and r.owner_id = auth.uid()
  )
);

drop policy if exists recipe_items_delete_policy on public.recipe_items;
create policy recipe_items_delete_policy
on public.recipe_items
for delete
to authenticated
using (
  exists (
    select 1
    from public.recipes r
    where r.id = recipe_items.recipe_id
      and r.owner_id = auth.uid()
  )
);

-- Likes are visible to signed-in users and can only be created/removed by self.
drop policy if exists recipe_likes_select_policy on public.recipe_likes;
create policy recipe_likes_select_policy
on public.recipe_likes
for select
to authenticated
using (true);

drop policy if exists recipe_likes_insert_policy on public.recipe_likes;
create policy recipe_likes_insert_policy
on public.recipe_likes
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.recipes r
    where r.id = recipe_likes.recipe_id
      and (r.is_public = true or r.owner_id = auth.uid())
  )
);

drop policy if exists recipe_likes_delete_policy on public.recipe_likes;
create policy recipe_likes_delete_policy
on public.recipe_likes
for delete
to authenticated
using (user_id = auth.uid());

-- Per-product cheapest price per protein gram, then roll up by recipe ingredients.
create or replace view public.recipe_metrics as
with product_price_per_protein as (
  select
    pr.product_code,
    min(
      pr.price / nullif((p.p / 100.0) * coalesce(nullif(pr.pack_weight_grams, 0), 100), 0)
    ) as min_price_per_protein_g
  from public.prices pr
  join public.products p on p.code = pr.product_code
  where pr.price > 0
    and p.p > 0
    and coalesce(nullif(pr.pack_weight_grams, 0), 100) > 0
  group by pr.product_code
),
recipe_item_values as (
  select
    ri.recipe_id,
    ri.product_code,
    ri.grams,
    (ri.grams / 100.0) * p.p as protein_g,
    (ri.grams / 100.0) * p.kcal as kcal,
    coalesce(pp.min_price_per_protein_g, 0) as min_price_per_protein_g
  from public.recipe_items ri
  join public.products p on p.code = ri.product_code
  left join product_price_per_protein pp on pp.product_code = ri.product_code
)
select
  riv.recipe_id,
  coalesce(sum(riv.protein_g), 0)::numeric(12,2) as protein_total_g,
  coalesce(sum(riv.kcal), 0)::numeric(12,2) as kcal_total,
  case
    when coalesce(sum(riv.kcal), 0) > 0
      then round(((sum(riv.protein_g) / sum(riv.kcal)) * 400)::numeric, 2)
    else 0
  end as score,
  case
    when coalesce(sum(riv.protein_g), 0) > 0
      then round(((sum(riv.protein_g * riv.min_price_per_protein_g) / sum(riv.protein_g)) * 100)::numeric, 2)
    else null
  end as cent_per_g_protein
from recipe_item_values riv
group by riv.recipe_id;

create or replace view public.recipe_feed as
select
  r.id,
  r.owner_id,
  r.title,
  r.description,
  r.is_public,
  r.created_at,
  r.updated_at,
  coalesce(p.username, split_part(p.email, '@', 1), 'User') as owner_name,
  coalesce(m.protein_total_g, 0) as protein_total_g,
  coalesce(m.kcal_total, 0) as kcal_total,
  coalesce(m.score, 0) as score,
  m.cent_per_g_protein,
  coalesce(l.like_count, 0) as like_count
from public.recipes r
left join public.profiles p on p.id = r.owner_id
left join public.recipe_metrics m on m.recipe_id = r.id
left join (
  select recipe_id, count(*)::int as like_count
  from public.recipe_likes
  group by recipe_id
) l on l.recipe_id = r.id;

grant select on public.recipe_metrics to anon, authenticated;
grant select on public.recipe_feed to anon, authenticated;
