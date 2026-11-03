import { describe, expect, test } from "bun:test"
import { QueryClient } from "@tanstack/react-query"
import { AxiosError, AxiosHeaders } from "axios"

import { Permission, type UserMePublic, UserRole } from "@/client"
import { currentUserQueryOptions } from "@/hooks/useAuth"
import {
  ForbiddenError,
  hasPermission,
  isForbiddenError,
  requirePermission,
} from "./permissions"

const manager: UserMePublic = {
  id: "00000000-0000-0000-0000-000000000001",
  email: "manager@example.com",
  role: UserRole.MANAGER,
  permissions: [Permission.USERS_LIST, Permission.METRICS_VIEW],
}

function axiosErrorWithStatus(status: number) {
  return new AxiosError("Request failed", undefined, undefined, undefined, {
    status,
    statusText: "",
    data: {},
    headers: {},
    config: { headers: new AxiosHeaders() },
  })
}

function contextWithCachedUser(user: UserMePublic) {
  const queryClient = new QueryClient()
  queryClient.setQueryData(currentUserQueryOptions.queryKey, user)
  return { context: { queryClient } }
}

describe("hasPermission", () => {
  test("is true only for permissions the backend granted", () => {
    expect(hasPermission(manager, Permission.USERS_LIST)).toBe(true)
    expect(hasPermission(manager, Permission.USERS_CREATE)).toBe(false)
  })

  test("is false while the user is unknown", () => {
    expect(hasPermission(undefined, Permission.USERS_LIST)).toBe(false)
    expect(hasPermission(null, Permission.USERS_LIST)).toBe(false)
  })

  test("trusts permissions, not the role name", () => {
    const adminWithoutPermissions = {
      ...manager,
      role: UserRole.ADMIN,
      permissions: [],
    }
    expect(hasPermission(adminWithoutPermissions, Permission.USERS_LIST)).toBe(
      false,
    )
  })
})

describe("requirePermission", () => {
  test("lets the navigation through when the cached user has the permission", async () => {
    const guard = requirePermission(Permission.METRICS_VIEW)

    await expect(guard(contextWithCachedUser(manager))).resolves.toBeUndefined()
  })

  test("throws ForbiddenError when the permission is missing", async () => {
    const guard = requirePermission(Permission.SETTINGS_MANAGE)

    const error = await guard(contextWithCachedUser(manager)).catch((e) => e)

    expect(error).toBeInstanceOf(ForbiddenError)
    expect(error.permission).toBe(Permission.SETTINGS_MANAGE)
  })
})

describe("isForbiddenError", () => {
  test("recognises guard denials and API 403s", () => {
    expect(isForbiddenError(new ForbiddenError(Permission.USERS_LIST))).toBe(
      true,
    )
    expect(isForbiddenError(axiosErrorWithStatus(403))).toBe(true)
  })

  test("ignores other failures", () => {
    expect(isForbiddenError(axiosErrorWithStatus(401))).toBe(false)
    expect(isForbiddenError(axiosErrorWithStatus(500))).toBe(false)
    expect(isForbiddenError(new Error("boom"))).toBe(false)
  })
})
