import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  buildSchema,
  isObjectType,
  isInputObjectType,
  isEnumType,
  isUnionType,
  isScalarType,
  isInterfaceType,
  type GraphQLSchema,
  type GraphQLField,
  type GraphQLInputField,
  type GraphQLType,
  GraphQLNonNull,
  GraphQLList,
} from "graphql";

const SDL_PATH = fileURLToPath(
  new URL("../../../schema/billing_core.graphql", import.meta.url),
);

export const sdl: string = readFileSync(SDL_PATH, "utf8");
export const schema: GraphQLSchema = buildSchema(sdl);

/** "[Money!]!" plus the innermost named type for cross-linking. */
export function typeRef(t: GraphQLType): { label: string; named: string } {
  if (t instanceof GraphQLNonNull) {
    const inner = typeRef(t.ofType);
    return { label: `${inner.label}!`, named: inner.named };
  }
  if (t instanceof GraphQLList) {
    const inner = typeRef(t.ofType);
    return { label: `[${inner.label}]`, named: inner.named };
  }
  return { label: t.name, named: t.name };
}

export interface FieldDoc {
  name: string;
  description: string | null;
  type: { label: string; named: string };
  args: {
    name: string;
    description: string | null;
    type: { label: string; named: string };
  }[];
}

function fieldDoc(f: GraphQLField<unknown, unknown>): FieldDoc {
  return {
    name: f.name,
    description: f.description ?? null,
    type: typeRef(f.type),
    args: f.args.map((a) => ({
      name: a.name,
      description: a.description ?? null,
      type: typeRef(a.type),
    })),
  };
}

function inputFieldDoc(f: GraphQLInputField): FieldDoc {
  return {
    name: f.name,
    description: f.description ?? null,
    type: typeRef(f.type),
    args: [],
  };
}

export interface TypeDoc {
  kind: "object" | "input" | "enum" | "union" | "scalar" | "interface";
  name: string;
  description: string | null;
  fields: FieldDoc[];
  enumValues: { name: string; description: string | null }[];
  unionMembers: string[];
}

function sortedTypes(schema: GraphQLSchema) {
  return Object.values(schema.getTypeMap())
    .filter((t) => !t.name.startsWith("__"))
    .sort((a, b) => a.name.localeCompare(b.name));
}

const rootNames = new Set(
  [schema.getQueryType()?.name, schema.getMutationType()?.name].filter(
    Boolean,
  ) as string[],
);

export const queryFields: FieldDoc[] = Object.values(
  schema.getQueryType()?.getFields() ?? {},
)
  .map(fieldDoc)
  .sort((a, b) => a.name.localeCompare(b.name));

export const mutationFields: FieldDoc[] = Object.values(
  schema.getMutationType()?.getFields() ?? {},
)
  .map(fieldDoc)
  .sort((a, b) => a.name.localeCompare(b.name));

export const typeDocs: TypeDoc[] = sortedTypes(schema)
  .filter((t) => !rootNames.has(t.name))
  .map((t): TypeDoc | null => {
    if (isObjectType(t) || isInterfaceType(t)) {
      return {
        kind: isObjectType(t) ? "object" : "interface",
        name: t.name,
        description: t.description ?? null,
        fields: Object.values(t.getFields()).map(fieldDoc),
        enumValues: [],
        unionMembers: [],
      };
    }
    if (isInputObjectType(t)) {
      return {
        kind: "input",
        name: t.name,
        description: t.description ?? null,
        fields: Object.values(t.getFields()).map(inputFieldDoc),
        enumValues: [],
        unionMembers: [],
      };
    }
    if (isEnumType(t)) {
      return {
        kind: "enum",
        name: t.name,
        description: t.description ?? null,
        fields: [],
        enumValues: t
          .getValues()
          .map((v) => ({ name: v.name, description: v.description ?? null })),
        unionMembers: [],
      };
    }
    if (isUnionType(t)) {
      return {
        kind: "union",
        name: t.name,
        description: t.description ?? null,
        fields: [],
        enumValues: [],
        unionMembers: t.getTypes().map((m) => m.name),
      };
    }
    if (isScalarType(t)) {
      return {
        kind: "scalar",
        name: t.name,
        description: t.description ?? null,
        fields: [],
        enumValues: [],
        unionMembers: [],
      };
    }
    return null;
  })
  .filter((t): t is TypeDoc => t !== null);

export const namedTypeSet = new Set(typeDocs.map((t) => t.name));
