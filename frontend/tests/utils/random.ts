const randomSuffix = () => crypto.randomUUID().slice(0, 8)

export const randomEmail = () => `test_${randomSuffix()}@example.com`

export const randomTeamName = () => `Team ${randomSuffix()}`

export const randomPassword = () => crypto.randomUUID()

export const slugify = (text: string) =>
  text
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^\w-]+/g, "")

export const randomItemTitle = () => `Item ${randomSuffix()}`

export const randomItemDescription = () => `Description ${randomSuffix()}`
