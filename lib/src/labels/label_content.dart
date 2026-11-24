import '../data/codes.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'label.dart';

/// An item's label: its name, then where it lives and its collection.
LabelContent itemLabel(Item item, {Collection? collection, List<Location> locations = const []}) {
  final location = locations.where((l) => l.id == item.locationId).firstOrNull;
  return LabelContent(
    code: labelCode(CodeKind.item, item.id),
    title: item.name,
    lines: [
      if (location != null) location.code.isNotEmpty ? location.code : location.name,
      ?collection?.name,
    ],
  );
}

/// A location's label: its name, its own code, and the places it's inside.
LabelContent locationLabel(Location location, List<Location> all) {
  final path = locationPath(location, all);
  final parents = path.contains(' › ') ? path.substring(0, path.lastIndexOf(' › ')) : '';
  return LabelContent(
    code: labelCode(CodeKind.location, location.id),
    title: location.name,
    lines: [location.code, parents],
  );
}
