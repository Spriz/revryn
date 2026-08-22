import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// The product feature docs in docs/features/ are the source of truth
// (INV-021); only `public: true` documents are rendered by the site.
const features = defineCollection({
  loader: glob({ pattern: ["*.md", "!README.md"], base: "../docs/features" }),
  schema: z
    .object({
      id: z.string(),
      title: z.string(),
      status: z.enum(["supported", "experimental", "deprecated"]),
      public: z.boolean().default(false),
      owners: z.array(z.string()).default([]),
      graphql: z.array(z.string()).default([]),
      adrs: z.array(z.string()).default([]),
    })
    .passthrough(),
});

export const collections = { features };
