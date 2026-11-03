import { type APIRequestContext, expect, test } from "@playwright/test"
import { firstSuperuser, firstSuperuserPassword } from "./config.ts"
import { createUser } from "./utils/privateApi"
import { randomEmail, randomPassword } from "./utils/random"
import { logInUser } from "./utils/user"

const api = `${process.env.VITE_API_URL}/api/v1`

async function logInToApi(request: APIRequestContext) {
  const login = await request.post(`${api}/login/access-token`, {
    form: { username: firstSuperuser, password: firstSuperuserPassword },
  })
  return { Authorization: `Bearer ${(await login.json()).access_token}` }
}

async function fetchUserCount(
  request: APIRequestContext,
  headers: Record<string, string>,
): Promise<number> {
  const users = await request.get(`${api}/users/`, {
    headers,
    params: { limit: 1 },
  })
  return (await users.json()).count
}

test("Admin page is accessible and shows correct title", async ({ page }) => {
  await page.goto("/admin")
  await expect(page).toHaveTitle("Users - FastAPI Template")
  await expect(page.getByRole("heading", { name: "Users" })).toBeVisible()
  await expect(
    page.getByText("Manage user accounts and permissions"),
  ).toBeVisible()
})

test("Add User button is visible", async ({ page }) => {
  await page.goto("/admin")
  await expect(page.getByRole("button", { name: "Add User" })).toBeVisible()
})

test.describe("Admin user management", () => {
  test("Create a new user successfully", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()
    const fullName = "Test User Admin"

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Full name").fill(fullName)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)

    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()

    await expect(page.getByRole("dialog")).not.toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow).toBeVisible()
  })

  test("Create an admin user", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await page.getByLabel("Role").click()
    await page.getByRole("option", { name: "Admin" }).click()
    await page.getByLabel("Is active?").check()

    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()

    await expect(page.getByRole("dialog")).not.toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow.getByText("Admin", { exact: true })).toBeVisible()
  })

  test("New users get the member role by default", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await expect(page.getByLabel("Role")).toHaveText("Member")

    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow.getByText("Member", { exact: true })).toBeVisible()
  })

  test("Change the role of a user", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()

    await page.getByRole("button", { name: "Add User" }).click()
    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()
    await expect(page.getByRole("dialog")).not.toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await userRow.getByRole("button").click()
    await page.getByRole("menuitem", { name: "Edit User" }).click()

    await page.getByLabel("Role").click()
    await page.getByRole("option", { name: "Manager" }).click()
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User updated successfully")).toBeVisible()
    await expect(userRow.getByText("Manager", { exact: true })).toBeVisible()
  })

  test("Edit a user successfully", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()
    const originalName = "Original Name"
    const updatedName = "Updated Name"

    await page.getByRole("button", { name: "Add User" }).click()
    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Full name").fill(originalName)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()
    await expect(page.getByRole("dialog")).not.toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await userRow.getByRole("button").click()

    await page.getByRole("menuitem", { name: "Edit User" }).click()

    await page.getByPlaceholder("Full name").fill(updatedName)
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User updated successfully")).toBeVisible()
    await expect(userRow.getByText(updatedName)).toBeVisible()
  })

  test("Delete a user successfully", async ({ page }) => {
    await page.goto("/admin")

    const email = randomEmail()
    const password = randomPassword()

    await page.getByRole("button", { name: "Add User" }).click()
    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()

    await expect(page.getByRole("dialog")).not.toBeVisible()

    const userRow = page.getByRole("row").filter({ hasText: email })
    await userRow.getByRole("button").click()

    await page.getByRole("menuitem", { name: "Delete User" }).click()

    await page.getByRole("button", { name: "Delete" }).click()

    await expect(
      page.getByText("The user was deleted successfully"),
    ).toBeVisible()

    await expect(
      page.getByRole("row").filter({ hasText: email }),
    ).not.toBeVisible()
  })

  test("Cancel user creation", async ({ page }) => {
    await page.goto("/admin")

    await page.getByRole("button", { name: "Add User" }).click()
    await page.getByPlaceholder("Email").fill("test@example.com")

    await page.getByRole("button", { name: "Cancel" }).click()

    await expect(page.getByRole("dialog")).not.toBeVisible()
  })

  test("Email is required and must be valid", async ({ page }) => {
    await page.goto("/admin")

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill("invalid-email")
    await page.getByPlaceholder("Email").blur()

    await expect(page.getByText("Invalid email address")).toBeVisible()
  })

  test("Password must be at least 8 characters", async ({ page }) => {
    await page.goto("/admin")

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill(randomEmail())
    await page.getByPlaceholder("Password").first().fill("short")
    await page.getByPlaceholder("Password").last().fill("short")
    await page.getByRole("button", { name: "Save" }).click()

    await expect(
      page.getByText("Password must be at least 8 characters"),
    ).toBeVisible()
  })

  test("Passwords must match", async ({ page }) => {
    await page.goto("/admin")

    await page.getByRole("button", { name: "Add User" }).click()

    await page.getByPlaceholder("Email").fill(randomEmail())
    await page.getByPlaceholder("Password").first().fill(randomPassword())
    await page.getByPlaceholder("Password").last().fill("different12345")
    await page.getByPlaceholder("Password").last().blur()

    await expect(page.getByText("The passwords don't match")).toBeVisible()
  })
})

test.describe("Users pagination", () => {
  test("Pages through users on the server", async ({ page, request }) => {
    const headers = await logInToApi(request)
    const pageSize = 10
    const missingUsers = pageSize + 1 - (await fetchUserCount(request, headers))
    for (let i = 0; i < missingUsers; i++) {
      await createUser({ email: randomEmail(), password: randomPassword() })
    }

    await page.goto("/admin")
    await expect(page.getByText(/Showing 1 to \d+ of/)).toBeVisible()
    const rows = page.getByRole("table").getByRole("row")
    const firstPage = await rows.allTextContents()

    await page.getByRole("button", { name: "Go to next page" }).click()

    await expect(page).toHaveURL(/page=2/)
    await expect.poll(() => rows.allTextContents()).not.toEqual(firstPage)
    const summary = page.getByText(/Showing 11 to \d+ of/)
    await expect(summary).toBeVisible()

    // Parallel tests change the total, so re-read both sides until they agree.
    await expect(async () => {
      await page.reload()
      await expect(summary).toBeVisible()
      const count = await fetchUserCount(request, headers)
      expect(await summary.textContent()).toContain(`of ${count} entries`)
    }).toPass()
  })

  test("A page past the end moves to the last page", async ({ page }) => {
    await page.goto("/admin?page=9999")

    await expect(page).not.toHaveURL(/page=9999/)
    await expect(page.getByRole("row").nth(1)).toBeVisible()
    await expect(page.getByText("No results found")).toHaveCount(0)
  })
})

test.describe("Users table on mobile", () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test("Keeps the role in view next to a long email", async ({ page }) => {
    const email = `a_rather_long_address_for_a_phone_${randomEmail()}`
    await createUser({ email, password: randomPassword() })

    await page.goto("/admin")

    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow.getByText("Member", { exact: true })).toBeInViewport({
      ratio: 1,
    })

    // The role must not stay in view by squeezing the user column.
    const emailBox = await userRow.getByText(email).boundingBox()
    expect(emailBox?.width).toBeGreaterThanOrEqual(192)
  })
})

test.describe("Admin page access control", () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test("User without users:list permission sees access denied", async ({
    page,
  }) => {
    const email = randomEmail()
    const password = randomPassword()

    await createUser({ email, password })
    await logInUser(page, email, password)

    await page.goto("/admin")

    await expect(page.getByTestId("access-denied")).toBeVisible()
    await expect(page.getByRole("heading", { name: "Users" })).not.toBeVisible()
    await expect(page).toHaveURL(/\/admin/)
  })

  test("Admin can access admin page", async ({ page }) => {
    await logInUser(page, firstSuperuser, firstSuperuserPassword)

    await page.goto("/admin")

    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible()
  })
})
