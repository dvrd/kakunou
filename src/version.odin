package sqlite

// Git tag of the latest release, exactly vMAJOR.MINOR.PATCH and nothing else.
// task release rewrites the loaded file and annotates that same tag.
VERSION :: #load("VERSION", string)
