// Users own tasks. Roles are plain strings; "admin" unlocks everything.
pub struct User {
    pub name: String,
    pub role: String,
    id: Int = 0,

    pub fn display(self) -> String {
        return self.name ++ "<" ++ self.role ++ ">";
    }
    pub fn is_admin(self) -> Bool {
        return self.role == "admin";
    }
}

pub fn make_user(name: String, role: String) -> User {
    return new User { name = name, role = role };
}

pub fn admin_user(name: String) -> User {
    return new User { name = name, role = "admin" };
}

pub fn user_display(u: User) -> String {
    return u.display();
}

pub fn user_is_admin(u: User) -> Bool {
    return u.is_admin();
}
