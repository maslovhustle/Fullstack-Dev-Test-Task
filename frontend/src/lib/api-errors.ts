import type { QueryKey } from "@tanstack/react-query"
import { AxiosError } from "axios"

import { currentUserQueryOptions } from "@/hooks/useAuth"

export type ApiErrorAction = "logout" | "refresh-permissions" | "none"

/**
 * 401: the session is no longer valid, so log out.
 * 403: the session is valid but not allowed; keep it and refetch the current
 * user in case their role changed (except when that query itself failed,
 * which would loop).
 */
export function apiErrorAction(
  error: unknown,
  queryKey?: QueryKey,
): ApiErrorAction {
  if (!(error instanceof AxiosError)) {
    return "none"
  }
  if (error.response?.status === 401) {
    return "logout"
  }
  const isCurrentUserQuery =
    queryKey?.[0] === currentUserQueryOptions.queryKey[0]
  if (error.response?.status === 403 && !isCurrentUserQuery) {
    return "refresh-permissions"
  }
  return "none"
}

const MAX_QUERY_RETRIES = 3

/** Retry network and server errors; 4xx answers will not change on retry. */
export function shouldRetryQuery(
  failureCount: number,
  error: unknown,
): boolean {
  const status =
    error instanceof AxiosError ? error.response?.status : undefined
  if (status !== undefined && status >= 400 && status < 500) {
    return false
  }
  return failureCount < MAX_QUERY_RETRIES
}
