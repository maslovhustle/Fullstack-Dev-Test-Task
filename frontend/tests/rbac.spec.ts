import { expect, type Page, test } from "@playwright/test"
import {
  firstSuperuser,
  firstSuperuserPassword,
  seedManager,
  seedManagerPassword,
  seedMember,
  seedMemberPassword,
} from "./config.ts"
import { randomEmail, randomPassword } from "./utils/random"
import { logInUser } from "./utils/user"

test.use({ storageState: { cookies: [], origins: [] } })

const navLink = (page: Page, name: string) =>
  page.getByRole("link", { name, exact: true })

async function expectStillLoggedIn(page: Page) {
  await expect(page.getByTestId("user-menu")).toBeVisible()
  const token = await page.evaluate(() => localStorage.getItem("access_token"))
  expect(token).toBeTruthy()
}

test.describe("Member", () => {
  test.beforeEach(async ({ page }) => {
    await logInUser(page, seedMember, seedMemberPassword)
  })

  test("Does not see users, metrics or system navigation", async ({ page }) => {
    await expect(navLink(page, "Items")).toBeVisible()
    await expect(navLink(page, "Users")).toHaveCount(0)
    await expect(navLink(page, "Metrics")).toHaveCount(0)
    await expect(navLink(page, "System")).toHaveCount(0)
  })

  test("Sees access denied on the admin page without being logged out", async ({
    page,
  }) => {
    await page.goto("/admin")

    await expect(page.getByTestId("access-denied")).toBeVisible()
    await expect(page).toHaveURL(/\/admin$/)
    await expectStillLoggedIn(page)

    await page.getByRole("link", { name: "Go to dashboard" }).click()
    await expect(page).toHaveURL("/")
    await expect(
      page.getByText("Welcome back, nice to see you again!"),
    ).toBeVisible()
  })

  test("Sees the danger zone tab in settings", async ({ page }) => {
    await page.goto("/settings")
    await expect(page.getByRole("tab", { name: "Danger zone" })).toBeVisible()
  })
})

test.describe("Manager", () => {
  test.beforeEach(async ({ page }) => {
    await logInUser(page, seedManager, seedManagerPassword)
  })

  test("Can list users but not manage them", async ({ page }) => {
    await navLink(page, "Users").click()

    await expect(page).toHaveURL("/admin")
    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible()
    await expect(page.getByText("View user accounts")).toBeVisible()
    await expect(page.getByRole("row").nth(1)).toBeVisible()
    await expect(page.getByRole("button", { name: "Add User" })).toHaveCount(0)
    await expect(page.getByRole("table").getByRole("button")).toHaveCount(0)
  })

  test("Can view metrics", async ({ page }) => {
    await navLink(page, "Metrics").click()

    await expect(page).toHaveURL("/metrics")
    await expect(page.getByRole("heading", { name: "Metrics" })).toBeVisible()
    await expect(page.getByText("Users by role")).toBeVisible()
  })

  test("Sees access denied on the system page without being logged out", async ({
    page,
  }) => {
    await page.goto("/system")

    await expect(page.getByTestId("access-denied")).toBeVisible()
    await expect(page).toHaveURL(/\/system$/)
    await expectStillLoggedIn(page)

    await navLink(page, "Metrics").click()
    await expect(page.getByRole("heading", { name: "Metrics" })).toBeVisible()
  })
})

test("A manager demoted mid-session sees access denied but stays logged in", async ({
  page,
  request,
}) => {
  const api = `${process.env.VITE_API_URL}/api/v1`
  const login = await request.post(`${api}/login/access-token`, {
    form: { username: firstSuperuser, password: firstSuperuserPassword },
  })
  const admin = { Authorization: `Bearer ${(await login.json()).access_token}` }
  const email = randomEmail()
  const password = randomPassword()
  const created = await request.post(`${api}/users/`, {
    headers: admin,
    data: { email, password, role: "manager", is_active: true },
  })
  const { id } = await created.json()

  await logInUser(page, email, password)
  await expect(navLink(page, "Metrics")).toBeVisible()

  await request.patch(`${api}/users/${id}`, {
    headers: admin,
    data: { role: "member" },
  })
  await navLink(page, "Metrics").click()

  await expect(page.getByTestId("access-denied")).toBeVisible()
  await expectStillLoggedIn(page)
  await expect(navLink(page, "Metrics")).toHaveCount(0)
  await expect(navLink(page, "Users")).toHaveCount(0)
})

test.describe("Admin", () => {
  test.beforeEach(async ({ page }) => {
    await logInUser(page, firstSuperuser, firstSuperuserPassword)
  })

  test("Sees users, metrics and system navigation", async ({ page }) => {
    await expect(navLink(page, "Users")).toBeVisible()
    await expect(navLink(page, "Metrics")).toBeVisible()
    await expect(navLink(page, "System")).toBeVisible()
  })

  test("Can open the system settings page", async ({ page }) => {
    await navLink(page, "System").click()

    await expect(
      page.getByRole("heading", { name: "System settings" }),
    ).toBeVisible()
    await expect(page.getByTestId("test-email-input")).toHaveValue(
      firstSuperuser,
    )
  })
})
