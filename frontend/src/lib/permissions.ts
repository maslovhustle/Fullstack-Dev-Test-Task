import type { QueryClient } from "@tanstack/react-query"
import { AxiosError } from "axios"

import type { Permission, UserMePublic } from "@/client"
import { currentUserQueryOptions } from "@/hooks/useAuth"

export class ForbiddenError extends Error {
  readonly permission: Permission

  constructor(permission: Permission) {
    super(`Missing permission: ${permission}`)
    this.name = "ForbiddenError"
    this.permission = permission
  }
}

export function hasPermission(
  user: UserMePublic | null | undefined,
  permission: Permission,
): boolean {
  return user?.permissions.includes(permission) ?? false
}

export function isForbiddenError(error: unknown): boolean {
  return (
    error instanceof ForbiddenError ||
    (error instanceof AxiosError && error.response?.status === 403)
  )
}

export function requirePermission(permission: Permission) {
  return async ({ context }: { context: { queryClient: QueryClient } }) => {
    const user = await context.queryClient.ensureQueryData(
      currentUserQueryOptions,
    )
    if (!hasPermission(user, permission)) {
      throw new ForbiddenError(permission)
    }
  }
}
