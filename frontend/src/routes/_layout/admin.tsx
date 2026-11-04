import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { createFileRoute, stripSearchParams } from "@tanstack/react-router"
import { useEffect } from "react"
import { z } from "zod"

import { Permission, type UserPublic, UsersService } from "@/client"
import AddUser from "@/components/Admin/AddUser"
import { columns, type UserTableData } from "@/components/Admin/columns"
import { DataTable } from "@/components/Common/DataTable"
import PendingUsers from "@/components/Pending/PendingUsers"
import useAuth from "@/hooks/useAuth"
import { hasPermission, requirePermission } from "@/lib/permissions"

const defaultUsersSearch = { page: 1, pageSize: 10 }

const usersSearchSchema = z.object({
  page: z.number().int().min(1).catch(defaultUsersSearch.page),
  // The API rejects a limit above 100.
  pageSize: z.number().int().min(1).max(100).catch(defaultUsersSearch.pageSize),
})

type UsersSearch = z.infer<typeof usersSearchSchema>

function getUsersQueryOptions({ page, pageSize }: UsersSearch) {
  return {
    queryFn: async () =>
      (
        await UsersService.readUsers({
          query: { skip: (page - 1) * pageSize, limit: pageSize },
        })
      ).data,
    queryKey: ["users", { page, pageSize }],
  }
}

export const Route = createFileRoute("/_layout/admin")({
  component: Admin,
  validateSearch: usersSearchSchema,
  search: { middlewares: [stripSearchParams(defaultUsersSearch)] },
  beforeLoad: requirePermission(Permission.USERS_LIST),
  head: () => ({
    meta: [
      {
        title: "Users - FastAPI Template",
      },
    ],
  }),
})

function UsersTable() {
  const { user: currentUser } = useAuth()
  const search = Route.useSearch()
  const navigate = Route.useNavigate()
  const { data: users, isPlaceholderData } = useQuery({
    ...getUsersQueryOptions(search),
    // Keep the current page on screen while the next one loads.
    placeholderData: keepPreviousData,
    throwOnError: true,
  })
  const canUpdate = hasPermission(currentUser, Permission.USERS_UPDATE)
  const canDelete = hasPermission(currentUser, Permission.USERS_DELETE)

  // Deleting the last user on a page, or an old link, can point past the end.
  const lastPage = Math.max(1, Math.ceil((users?.count ?? 0) / search.pageSize))
  const isPastLastPage = users && !isPlaceholderData && search.page > lastPage
  useEffect(() => {
    if (isPastLastPage) {
      navigate({ search: { ...search, page: lastPage }, replace: true })
    }
  }, [isPastLastPage, lastPage, navigate, search])

  if (!users) {
    return <PendingUsers />
  }

  const tableData: UserTableData[] = users.data.map((user: UserPublic) => ({
    ...user,
    isCurrentUser: currentUser?.id === user.id,
    canUpdate,
    canDelete,
  }))

  return (
    <DataTable
      columns={columns}
      data={tableData}
      serverPagination={{
        state: { pageIndex: search.page - 1, pageSize: search.pageSize },
        rowCount: users.count,
        onChange: ({ pageIndex, pageSize }) =>
          navigate({ search: { page: pageIndex + 1, pageSize } }),
      }}
    />
  )
}

function Admin() {
  const { user: currentUser } = useAuth()
  const canCreate = hasPermission(currentUser, Permission.USERS_CREATE)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Users</h1>
          <p className="text-muted-foreground">
            {canCreate
              ? "Manage user accounts and permissions"
              : "View user accounts"}
          </p>
        </div>
        {canCreate && <AddUser />}
      </div>
      <UsersTable />
    </div>
  )
}
