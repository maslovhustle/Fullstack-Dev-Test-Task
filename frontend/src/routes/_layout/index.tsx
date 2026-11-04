import { createFileRoute } from "@tanstack/react-router"

import { Badge } from "@/components/ui/badge"
import useAuth from "@/hooks/useAuth"
import { capitalize } from "@/utils"

export const Route = createFileRoute("/_layout/")({
  component: Dashboard,
  head: () => ({
    meta: [
      {
        title: "Dashboard - FastAPI Template",
      },
    ],
  }),
})

function Dashboard() {
  const { user: currentUser } = useAuth()

  return (
    <div>
      <div>
        <div className="flex items-center gap-3">
          <h1 className="text-2xl truncate max-w-sm">
            Hi, {currentUser?.full_name || currentUser?.email} 👋
          </h1>
          {currentUser && (
            <Badge variant="secondary" data-testid="user-role">
              {capitalize(currentUser.role)}
            </Badge>
          )}
        </div>
        <p className="text-muted-foreground">
          Welcome back, nice to see you again!!!
        </p>
      </div>
    </div>
  )
}
