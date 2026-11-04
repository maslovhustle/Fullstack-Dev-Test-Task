import type { ColumnDef } from "@tanstack/react-table"

import type { UserPublic } from "@/client"
import type { DataTableFeatures } from "@/components/Common/DataTable"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { capitalize } from "@/utils"
import { UserActionsMenu } from "./UserActionsMenu"

export type UserTableData = UserPublic & {
  isCurrentUser: boolean
  canUpdate: boolean
  canDelete: boolean
}

export const columns: ColumnDef<DataTableFeatures, UserTableData>[] = [
  {
    accessorKey: "full_name",
    header: "User",
    cell: ({ row }) => {
      const { full_name: fullName, email, isCurrentUser } = row.original
      return (
        // A fixed width on small screens wraps long values, keeping the role in view.
        <div className="flex flex-col gap-0.5 max-sm:w-48 max-sm:whitespace-normal max-sm:wrap-anywhere">
          <div className="flex items-center gap-2">
            <span
              className={cn(
                "font-medium",
                !fullName && "text-muted-foreground",
              )}
            >
              {fullName || "N/A"}
            </span>
            {isCurrentUser && (
              <Badge variant="outline" className="text-xs">
                You
              </Badge>
            )}
          </div>
          <span className="text-muted-foreground">{email}</span>
        </div>
      )
    },
  },
  {
    accessorKey: "role",
    header: "Role",
    cell: ({ row }) => (
      <Badge variant="secondary">{capitalize(row.original.role)}</Badge>
    ),
  },
  {
    accessorKey: "is_active",
    header: "Status",
    cell: ({ row }) => (
      <div className="flex items-center gap-2">
        <span
          className={cn(
            "size-2 rounded-full",
            row.original.is_active ? "bg-green-500" : "bg-gray-400",
          )}
        />
        <span className={row.original.is_active ? "" : "text-muted-foreground"}>
          {row.original.is_active ? "Active" : "Inactive"}
        </span>
      </div>
    ),
  },
  {
    id: "actions",
    header: () => <span className="sr-only">Actions</span>,
    cell: ({ row }) => {
      const { canUpdate, canDelete } = row.original
      if (!canUpdate && !canDelete) {
        return null
      }
      return (
        <div className="flex justify-end">
          <UserActionsMenu
            user={row.original}
            canUpdate={canUpdate}
            canDelete={canDelete}
          />
        </div>
      )
    },
  },
]
