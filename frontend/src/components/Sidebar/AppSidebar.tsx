import { Briefcase, ChartColumn, Home, Settings2, Users } from "lucide-react"

import { Permission } from "@/client"
import { SidebarAppearance } from "@/components/Common/Appearance"
import { Logo } from "@/components/Common/Logo"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
} from "@/components/ui/sidebar"
import useAuth from "@/hooks/useAuth"
import { hasPermission } from "@/lib/permissions"
import { type Item, Main } from "./Main"
import { User } from "./User"

const navItems: Item[] = [
  { icon: Home, title: "Dashboard", path: "/" },
  {
    icon: Briefcase,
    title: "Items",
    path: "/items",
    permission: Permission.ITEMS_USE,
  },
  {
    icon: Users,
    title: "Admin",
    path: "/admin",
    permission: Permission.USERS_LIST,
  },
  {
    icon: ChartColumn,
    title: "Metrics",
    path: "/metrics",
    permission: Permission.METRICS_VIEW,
  },
  {
    icon: Settings2,
    title: "System",
    path: "/system",
    permission: Permission.SETTINGS_MANAGE,
  },
]

export function AppSidebar() {
  const { user: currentUser } = useAuth()

  const items = navItems.filter(
    (item) => !item.permission || hasPermission(currentUser, item.permission),
  )

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="px-4 py-6 group-data-[collapsible=icon]:px-0 group-data-[collapsible=icon]:items-center">
        <Logo variant="responsive" />
      </SidebarHeader>
      <SidebarContent>
        <Main items={items} />
      </SidebarContent>
      <SidebarFooter>
        <SidebarAppearance />
        <User user={currentUser} />
      </SidebarFooter>
    </Sidebar>
  )
}

export default AppSidebar
