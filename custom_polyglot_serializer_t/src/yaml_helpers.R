r_write_yaml <- function(object, path) {
  yaml::write_yaml(object, path)
}

r_read_yaml <- function(path) {
  yaml::read_yaml(path)
}
