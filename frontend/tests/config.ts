import path from "node:path"
import { fileURLToPath } from "node:url"
import dotenv from "dotenv"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

dotenv.config({ path: path.join(__dirname, "../../.env") })

function getEnvVar(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Environment variable ${name} is undefined`)
  }
  return value
}

export const firstSuperuser = getEnvVar("FIRST_SUPERUSER")
export const firstSuperuserPassword = getEnvVar("FIRST_SUPERUSER_PASSWORD")
export const seedManager = getEnvVar("SEED_MANAGER_EMAIL")
export const seedManagerPassword = getEnvVar("SEED_MANAGER_PASSWORD")
export const seedMember = getEnvVar("SEED_MEMBER_EMAIL")
export const seedMemberPassword = getEnvVar("SEED_MEMBER_PASSWORD")
