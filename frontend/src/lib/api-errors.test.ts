import { describe, expect, test } from "bun:test"
import { AxiosError, AxiosHeaders } from "axios"

import { currentUserQueryOptions } from "@/hooks/useAuth"
import { apiErrorAction, shouldRetryQuery } from "./api-errors"

function axiosErrorWithStatus(status: number) {
  return new AxiosError("Request failed", undefined, undefined, undefined, {
    status,
    statusText: "",
    data: {},
    headers: {},
    config: { headers: new AxiosHeaders() },
  })
}

describe("apiErrorAction", () => {
  test("logs out on 401", () => {
    expect(apiErrorAction(axiosErrorWithStatus(401), ["users"])).toBe("logout")
  })

  test("keeps the session on 403 and refreshes permissions", () => {
    expect(apiErrorAction(axiosErrorWithStatus(403), ["users"])).toBe(
      "refresh-permissions",
    )
    expect(apiErrorAction(axiosErrorWithStatus(403))).toBe(
      "refresh-permissions",
    )
  })

  test("does not refetch the current user when that query itself is forbidden", () => {
    expect(
      apiErrorAction(
        axiosErrorWithStatus(403),
        currentUserQueryOptions.queryKey,
      ),
    ).toBe("none")
  })

  test("ignores other errors", () => {
    expect(apiErrorAction(axiosErrorWithStatus(500), ["users"])).toBe("none")
    expect(apiErrorAction(new Error("network down"))).toBe("none")
  })
})

describe("shouldRetryQuery", () => {
  test("never retries client errors such as 401, 403 or 404", () => {
    for (const status of [401, 403, 404, 422]) {
      expect(shouldRetryQuery(0, axiosErrorWithStatus(status))).toBe(false)
    }
  })

  test("retries server and network errors up to three times", () => {
    expect(shouldRetryQuery(0, axiosErrorWithStatus(503))).toBe(true)
    expect(shouldRetryQuery(2, new Error("network down"))).toBe(true)
    expect(shouldRetryQuery(3, axiosErrorWithStatus(503))).toBe(false)
  })
})
