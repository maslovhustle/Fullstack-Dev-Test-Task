import { useSuspenseQuery } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { Suspense } from "react"

import { MetricsService, Permission, UserRole } from "@/client"
import PendingMetrics from "@/components/Pending/PendingMetrics"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { requirePermission } from "@/lib/permissions"
import { capitalize } from "@/utils"

function getMetricsQueryOptions() {
  return {
    queryFn: async () => (await MetricsService.readMetrics()).data,
    queryKey: ["metrics"],
  }
}

export const Route = createFileRoute("/_layout/metrics")({
  component: Metrics,
  beforeLoad: requirePermission(Permission.METRICS_VIEW),
  head: () => ({
    meta: [
      {
        title: "Metrics - FastAPI Template",
      },
    ],
  }),
})

interface StatCardProps {
  title: string
  value: number
}

function StatCard({ title, value }: StatCardProps) {
  return (
    <Card className="gap-2">
      <CardHeader>
        <CardDescription>{title}</CardDescription>
      </CardHeader>
      <CardContent>
        <p className="text-3xl font-semibold tabular-nums">{value}</p>
      </CardContent>
    </Card>
  )
}

function MetricsContent() {
  const { data: metrics } = useSuspenseQuery(getMetricsQueryOptions())

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-3">
        <StatCard title="Total users" value={metrics.total_users} />
        <StatCard title="Active users" value={metrics.active_users} />
        <StatCard title="Items" value={metrics.total_items} />
      </div>
      <Card>
        <CardHeader>
          <CardTitle>Users by role</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {Object.values(UserRole).map((role) => (
            <div key={role} className="flex items-center justify-between">
              <span className="text-muted-foreground">{capitalize(role)}</span>
              <span className="font-medium tabular-nums">
                {metrics.users_by_role[role] ?? 0}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}

function Metrics() {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Metrics</h1>
        <p className="text-muted-foreground">
          Overview of users and items across the system
        </p>
      </div>
      <Suspense fallback={<PendingMetrics />}>
        <MetricsContent />
      </Suspense>
    </div>
  )
}
